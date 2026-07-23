import Foundation
@preconcurrency import VentusCore
import VentusIPC
import os.log

// MARK: - Telemetry Data Structures (Simplified for serialization)

struct TelemetrySnapshot: Codable, Sendable {
    struct FanInfo: Codable, Sendable {
        let fanIndex: Int
        let actualRPM: Double
        let targetRPM: Double
    }

    struct SensorInfo: Codable, Sendable {
        let groupName: String
        let maxTemp: Double
        let meanTemp: Double
        let count: Int
    }

    struct Explanation: Codable, Sendable {
        let fan: Int
        let targetRPM: Double
        let winner: String
    }

    let mode: String  // "observe" or "armed"
    let activeProfile: String
    let activeRule: String?
    let timestamp: Date
    let uptime: TimeInterval
    let sensors: [SensorInfo]
    let fans: [FanInfo]
    let packageWatts: Double?
    let explanations: [Explanation]
    let version: String
}

// MARK: - Global Logger

let logger = os.Logger(subsystem: "com.formm.ventus", category: "daemon")

func logMessage(_ message: String) {
    logger.log("\(message, privacy: .public)")
    fputs(message + "\n", stderr)
    fflush(stderr)
}

// MARK: - Daemon State

final class DaemonState {
    var config: Config
    var armed: Bool = false
    var activeProfile: String = "balanced"
    let sensorReader: SensorReader
    let powerReader: PowerReader
    var smcClient: SMCClient?
    let curveEngine: CurveEngine
    let ruleEngine: RuleEngine
    let supervisor: SafetySupervisor
    let heartbeatWatchdog: ControlLoopWatchdog
    let cpuWatchdog: SelfCPUWatchdog
    let startTime: Date
    var lastExplanations: [CurveEngine.Explanation] = []
    var lastSensorSnapshot: [SensorGroup: GroupReading] = [:]
    var lastPowerReading: PowerReader.PowerReading?
    var lastFanActuals: [Int: Double] = [:]
    var lastActiveRule: String?

    init(config: Config) throws {
        self.config = config
        self.armed = config.armed
        self.sensorReader = SensorReader(logger: logMessage)
        self.powerReader = PowerReader(logger: logMessage)
        self.smcClient = SMCClient(logger: logMessage)
        self.curveEngine = CurveEngine(logger: logMessage)
        self.ruleEngine = RuleEngine(logger: logMessage)
        self.supervisor = SafetySupervisor(armed: config.armed, logger: logMessage)
        self.heartbeatWatchdog = ControlLoopWatchdog(stallThresholdS: 10, logger: logMessage)
        self.cpuWatchdog = SelfCPUWatchdog(logger: logMessage)
        self.startTime = Date()

        logMessage("[DaemonState] Initialized (armed: \(config.armed))")
    }

    func getSnapshot() -> TelemetrySnapshot {
        let mode = armed ? "armed" : "observe"
        let activeProfile = config.pinnedProfile ?? "balanced"

        var sensorInfos: [TelemetrySnapshot.SensorInfo] = []
        for (group, reading) in lastSensorSnapshot {
            sensorInfos.append(TelemetrySnapshot.SensorInfo(
                groupName: group.rawValue,
                maxTemp: reading.max,
                meanTemp: reading.mean,
                count: reading.count
            ))
        }

        var fanInfos: [TelemetrySnapshot.FanInfo] = []
        for explanation in lastExplanations {
            fanInfos.append(TelemetrySnapshot.FanInfo(
                fanIndex: explanation.fan,
                actualRPM: lastFanActuals[explanation.fan] ?? 0,
                targetRPM: explanation.targetRPM
            ))
        }

        let explanations = lastExplanations.map { exp in
            TelemetrySnapshot.Explanation(fan: exp.fan, targetRPM: exp.targetRPM, winner: exp.winner)
        }

        let uptime = Date().timeIntervalSince(startTime)
        let version = "1.0.0"

        return TelemetrySnapshot(
            mode: mode,
            activeProfile: activeProfile,
            activeRule: lastActiveRule,
            timestamp: Date(),
            uptime: uptime,
            sensors: sensorInfos,
            fans: fanInfos,
            packageWatts: lastPowerReading?.totalW,
            explanations: explanations,
            version: version
        )
    }

    func setArmed(_ newArmed: Bool) {
        armed = newArmed
        config.armed = newArmed
        supervisor.setArmed(newArmed)
    }

    func restoreAuto() {
        guard let smc = smcClient else {
            logMessage("[DaemonState] restoreAuto: SMC unavailable, cannot restore")
            return
        }
        let fanCount = smc.listFanCount()
        for i in 0 ..< fanCount {
            smc.setFanMode(i, mode: 0)  // 0 = auto
        }
        logMessage("[DaemonState] Restored all fans to auto mode")
    }
}

// MARK: - Main Control Loop

class DaemonController {
    private let state: DaemonState
    private let dryRun: Bool
    private let serialQueue = DispatchQueue(label: "com.formm.ventus.control-loop", qos: .utility)
    private var controlLoopTimer: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "com.formm.ventus.watchdog", qos: .utility)
    private var shouldKeepRunning = true
    // NSXPCListener.delegate is weak — both MUST be retained here or every
    // incoming connection is silently rejected after setupXPCServer() returns.
    private var xpcListener: NSXPCListener?
    private var xpcDelegate: VentusXPCServerDelegate?

    // CRITICAL: Retain signal sources and replace their default handlers (FIX #2)
    private var sigTermSource: DispatchSourceSignal?
    private var sigIntSource: DispatchSourceSignal?
    // Signals run on their OWN queue, never serialQueue — a stalled control loop
    // must not block SIGTERM cleanup.
    private let signalQueue = DispatchQueue(label: "com.formm.ventus.signals")

    // Hardware ownership: `hardwareLock` guards every SMC control-write region so
    // the control loop, watchdog, and signal handler can never interleave writes.
    // `emergencyStop` (guarded by the same lock) latches true when watchdog/signal
    // restores auto; once set, the control loop performs NO further writes. This
    // closes the "watchdog restores → loop re-forces → watchdog exits" race
    // without the watchdog ever blocking on the (possibly stalled) control queue.
    private let hardwareLock = NSLock()
    private var emergencyStop = false

    /// Latches emergency stop and restores all fans to auto under the hardware lock.
    /// Safe to call from any queue; idempotent.
    private func emergencyRestore(reason: String) {
        hardwareLock.lock()
        emergencyStop = true
        logMessage("[EmergencyRestore] \(reason) — restoring all fans to auto")
        state.restoreAuto()
        hardwareLock.unlock()
    }

    init(dryRun: Bool = false) throws {
        self.dryRun = dryRun

        // Load or create config
        var config = loadConfig() ?? Config.defaultConfig()
        config.armed = false  // Always start in observe mode

        self.state = try DaemonState(config: config)

        logMessage("[DaemonController] Initialized (dryRun: \(dryRun))")
    }

    func run() {
        logMessage("[DaemonController] run() called, dryRun: \(dryRun)")
        if dryRun {
            runDryRun()
        } else {
            runDaemon()
        }
    }

    private func runDaemon() {
        logMessage("[Daemon] Starting in normal mode")

        // Register signal handlers
        setupSignalHandlers()

        // CRITICAL: Unconditionally restore auto on startup (FIX #1)
        // This ensures that after SIGKILL + launchd restart, fans revert to Apple auto
        logMessage("[Daemon] Performing startup restoreAuto (idempotent, safe when SMC unavailable)")
        state.restoreAuto()

        // Start the control loop
        startControlLoop()

        // Start watchdog on independent queue
        startWatchdog()

        // Block on RunLoop/dispatchMain
        dispatchMain()
    }

    // MARK: - XPC Server Setup

    private func setupXPCServer() {
        logMessage("[XPC] Setting up NSXPCListener for com.formm.ventus.daemon")

        let listener = NSXPCListener(machServiceName: "com.formm.ventus.daemon")
        let delegate = VentusXPCServerDelegate(controller: self)
        listener.delegate = delegate
        xpcListener = listener
        xpcDelegate = delegate
        listener.resume()

        logMessage("[XPC] Listener activated on com.formm.ventus.daemon")
    }

    // MARK: - Control Loop

    private func startControlLoop() {
        setupXPCServer()

        serialQueue.async { [weak self] in
            self?.runControlLoop()
        }
    }

    private func runControlLoop() {
        logMessage("[ControlLoop] Starting on serial queue")
        scheduleNextControlTick(1.0)
    }

    private func scheduleNextControlTick(_ tickS: Double) {
        let timer = DispatchSource.makeTimerSource(queue: serialQueue)
        self.controlLoopTimer = timer

        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let newTickS = self.controlLoopStep()
            self.scheduleNextControlTick(newTickS)
        }

        let deadline = DispatchTime.now() + .milliseconds(Int(tickS * 1000))
        timer.schedule(deadline: deadline)
        timer.resume()
    }

    private func controlLoopStep() -> Double {
        let now = Date()

        // Record heartbeat for watchdog
        state.heartbeatWatchdog.recordHeartbeat()

        // Record CPU usage sample
        let rusage = getrusage()
        let rusageSecs = Double(rusage.ru_utime.tv_sec) + Double(rusage.ru_utime.tv_usec) / 1e6
            + Double(rusage.ru_stime.tv_sec) + Double(rusage.ru_stime.tv_usec) / 1e6
        state.cpuWatchdog.recordSample(rusageSecs, at: now)

        // Read hardware
        let sensors = state.sensorReader.snapshot()
        let power = state.powerReader.readPower()
        let fanCount = state.smcClient?.listFanCount() ?? 2

        // FIX #7: Sensor failure detection — if cpuPerf+gpu+soc all absent, treat as failure
        let criticalGroupsMissing = !sensors.keys.contains(.cpuPerf)
            && !sensors.keys.contains(.gpu)
            && !sensors.keys.contains(.soc)

        if criticalGroupsMissing {
            logMessage("[ControlLoop] SENSOR FAILURE: critical groups (cpuPerf/gpu/soc) all absent")
            if state.armed {
                logMessage("[ControlLoop] Armed mode detected during sensor failure — restoring auto and entering observe")
                hardwareLock.lock()
                state.restoreAuto()
                hardwareLock.unlock()
                state.setArmed(false)
                saveConfig(state.config)
            }
            return 5.0  // Return to cool tick, don't make decisions on missing sensors
        }

        var fanActuals: [Int: Double] = [:]
        for i in 0 ..< fanCount {
            if let actual = state.smcClient?.readFanActual(i) {
                fanActuals[i] = Double(actual)
            }
        }

        // Get thermal state
        let thermalState = getThermalState()

        // Evaluate active profile
        let activeProfile = state.config.pinnedProfile ?? "balanced"

        // Run curve engine
        guard let profile = state.config.profiles[activeProfile] else {
            return 5.0  // Default to cool tick if profile missing
        }

        let explanations = state.curveEngine.compute(
            sensors: sensors,
            profile: profile,
            actualRPMs: fanActuals,
            now: now,
            thermalState: thermalState,
            safetyOverride: 0,
            packageWatts: power?.totalW
        )

        // Apply safety supervisor check
        let safetyRPM = state.supervisor.getSafetyOverrideRPM(
            maxRPM: (profile.curves.first?.value.points.last?.rpm ?? 6000),
            sensors: sensors,
            thermalState: thermalState
        )

        // All hardware writes happen under hardwareLock so the watchdog/signal
        // handler cannot interleave. If emergencyStop latched, write nothing.
        hardwareLock.lock()
        if !emergencyStop && state.armed {
            if safetyRPM > 0 {
                // Thermal override wins unconditionally (even for curve-less
                // profiles): force EVERY fan to its own hardware max. This is
                // checked BEFORE the auto-apple release so an emergency is never
                // cancelled by a curve-less active profile.
                for i in 0 ..< fanCount {
                    let hardwareMax = state.smcClient?.readFanMax(i) ?? 6800
                    state.smcClient?.forceFan(i, rpm: Float(hardwareMax))
                }
            } else if profile.curves.isEmpty {
                // auto-apple (no curves) and no emergency: release fans to macOS.
                logMessage("[ControlLoop] Active profile '\(activeProfile)' has no curves — restoring fans to auto")
                state.restoreAuto()
            } else {
                // Normal operation: forceFan sets target then forces mode ONLY if
                // the target write succeeded (never forces at a stale target).
                for explanation in explanations {
                    state.smcClient?.forceFan(explanation.fan, rpm: Float(explanation.targetRPM))
                }
            }
        }
        hardwareLock.unlock()

        // Update state snapshot
        state.lastSensorSnapshot = sensors
        state.lastPowerReading = power
        state.lastFanActuals = fanActuals
        state.lastExplanations = explanations
        state.lastActiveRule = nil

        // Determine next tick interval from engine
        let nextTickS = state.curveEngine.suggestedTickS
        return nextTickS
    }

    // MARK: - Watchdog Thread

    private func startWatchdog() {
        watchdogQueue.async { [weak self] in
            self?.runWatchdog()
        }
    }

    private func runWatchdog() {
        logMessage("[Watchdog] Starting independent watchdog thread")

        while shouldKeepRunning {
            Thread.sleep(forTimeInterval: 0.5)

            let now = Date()

            // Check control loop heartbeat
            if state.heartbeatWatchdog.isStalled(now: now) {
                let stallTime = state.heartbeatWatchdog.secondsSinceHeartbeat(now: now)
                emergencyRestore(reason: "Control loop stalled \(String(format: "%.1f", stallTime))s")
                exit(1)
            }

            // Check self-CPU usage
            if state.cpuWatchdog.isHighCPU(now: now) {
                let cpuPercent = state.cpuWatchdog.measureCPUPercent(now: now)
                emergencyRestore(reason: "Self-CPU high (\(String(format: "%.1f", cpuPercent * 100))%)")
                exit(1)
            }
        }
    }

    // MARK: - Signal Handlers

    private func setupSignalHandlers() {
        // Signal sources live on signalQueue (NOT serialQueue): a stalled control
        // loop must never delay SIGTERM cleanup. SIG_IGN is installed FIRST (in
        // main, before the run loop) so no default-disposition window exists;
        // re-assert here defensively.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        sigTermSource.setEventHandler { [weak self] in self?.handleSignal() }
        sigIntSource.setEventHandler { [weak self] in self?.handleSignal() }
        sigTermSource.resume()
        sigIntSource.resume()

        // Retain sources as properties so they are not freed.
        self.sigTermSource = sigTermSource
        self.sigIntSource = sigIntSource
    }

    private func handleSignal() {
        shouldKeepRunning = false
        emergencyRestore(reason: "Caught SIGTERM/SIGINT")
        exit(0)
    }

    // MARK: - XPC Methods

    func getStatusXPC() -> Data? {
        let snapshot = state.getSnapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(snapshot)
    }

    func getConfigXPC() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(state.config)
    }

    /// All state-mutating XPC operations run to completion on serialQueue and
    /// return the REAL result, so callers never receive an ack before the effect
    /// (and see SMC failures). serialQueue.sync from the XPC queue is deadlock-free:
    /// the control loop never blocks on the XPC queue.
    func setConfigXPC(_ configData: Data) -> XPCResult {
        serialQueue.sync {
            do {
                let newConfig = try JSONDecoder().decode(Config.self, from: configData)
                try newConfig.validate()
                let wasArmed = state.armed
                state.setArmed(false)
                state.config = newConfig
                saveConfig(newConfig)
                if wasArmed { state.setArmed(true) }
                logMessage("[XPC] Config updated via setConfig")
                return .ok()
            } catch {
                let errorMsg = "Config validation failed: \(error)"
                logMessage("[XPC] \(errorMsg)")
                return .error(errorMsg)
            }
        }
    }

    func setProfileXPC(_ profileName: String) -> XPCResult {
        serialQueue.sync {
            guard state.config.profiles[profileName] != nil else {
                let errorMsg = "Profile '\(profileName)' not found"
                logMessage("[XPC] \(errorMsg)")
                return .error(errorMsg)
            }
            state.config.pinnedProfile = profileName
            saveConfig(state.config)
            logMessage("[XPC] Profile pinned to \(profileName)")
            return .ok()
        }
    }

    func armXPC() -> XPCResult {
        serialQueue.sync {
            guard !emergencyStop else {
                return .error("Cannot arm: daemon is in emergency-stop state")
            }
            state.setArmed(true)
            saveConfig(state.config)
            logMessage("[XPC] Armed mode enabled")
            return .ok()
        }
    }

    func disarmXPC() -> XPCResult {
        serialQueue.sync {
            // Clear armed FIRST, then restore hardware under the lock — so no
            // control tick can re-force between the restore and the state change.
            state.setArmed(false)
            hardwareLock.lock()
            state.restoreAuto()
            hardwareLock.unlock()
            saveConfig(state.config)
            logMessage("[XPC] Disarmed; fans restored to auto")
            return .ok()
        }
    }

    func setAppleAutoXPC() -> XPCResult {
        serialQueue.sync {
            state.setArmed(false)
            hardwareLock.lock()
            state.restoreAuto()
            hardwareLock.unlock()
            saveConfig(state.config)
            logMessage("[XPC] Fans restored to Apple auto")
            return .ok()
        }
    }

    private func runDryRun() {
        logMessage("[DryRun] Starting foreground observe mode")
        print("Ventus Daemon v1.0.0 (--dry-run mode)")
        print("Press Ctrl-C to exit\n")
        fflush(stdout)

        for tickCount in 0 ..< 8 {
            let telemetry = dryRunControlStep()

            let sensorLine = telemetry.sensors.isEmpty
                ? "(no sensors)"
                : telemetry.sensors.map { "\($0.groupName):\(String(format: "%.0f", $0.maxTemp))°C" }.joined(separator: " ")
            let fanLine = telemetry.fans.isEmpty
                ? "(no fans)"
                : telemetry.fans.map { "F\($0.fanIndex):\(Int($0.actualRPM))/\(Int($0.targetRPM))" }.joined(separator: " ")
            let wattLine = telemetry.packageWatts.map { String(format: "%.0fW", $0) } ?? "N/A"

            print("[\(String(format: "%04d", tickCount))] Sensors: \(sensorLine) | Fans: \(fanLine) | Power: \(wattLine) | Mode: \(telemetry.mode)")
            fflush(stdout)

            Thread.sleep(forTimeInterval: 1.0)
        }

        logMessage("[DryRun] 8 ticks complete, exiting")
    }

    private func dryRunControlStep() -> TelemetrySnapshot {
        let now = Date()

        // Record heartbeat
        state.heartbeatWatchdog.recordHeartbeat()

        // Record CPU usage sample
        let rusage = getrusage()
        let rusageSecs = Double(rusage.ru_utime.tv_sec) + Double(rusage.ru_utime.tv_usec) / 1e6
            + Double(rusage.ru_stime.tv_sec) + Double(rusage.ru_stime.tv_usec) / 1e6
        state.cpuWatchdog.recordSample(rusageSecs, at: now)

        // Read hardware
        let sensors = state.sensorReader.snapshot()
        let power = state.powerReader.readPower()
        let fanCount = state.smcClient?.listFanCount() ?? 2

        var fanActuals: [Int: Double] = [:]
        for i in 0 ..< fanCount {
            if let actual = state.smcClient?.readFanActual(i) {
                fanActuals[i] = Double(actual)
            }
        }

        // Get thermal state
        let thermalState = getThermalState()

        // Evaluate active profile
        let activeProfile = state.config.pinnedProfile ?? "balanced"

        // Run curve engine
        guard let profile = state.config.profiles[activeProfile] else {
            return state.getSnapshot()
        }

        let explanations = state.curveEngine.compute(
            sensors: sensors,
            profile: profile,
            actualRPMs: fanActuals,
            now: now,
            thermalState: thermalState,
            safetyOverride: 0,
            packageWatts: power?.totalW
        )

        // Update state snapshot (no SMC writes in dry-run)
        state.lastSensorSnapshot = sensors
        state.lastPowerReading = power
        state.lastFanActuals = fanActuals
        state.lastExplanations = explanations
        state.lastActiveRule = nil

        return state.getSnapshot()
    }
}

// MARK: - Thermal State

func getThermalState() -> ThermalState {
    let processInfo = ProcessInfo.processInfo
    switch processInfo.thermalState {
    case .nominal:
        return .nominal
    case .fair:
        return .fair
    case .serious:
        return .serious
    case .critical:
        return .critical
    @unknown default:
        return .nominal
    }
}

func getrusage() -> rusage {
    var ru = rusage()
    Darwin.getrusage(RUSAGE_SELF, &ru)
    return ru
}

// MARK: - Config Management

func loadConfig() -> Config? {
    let configPath = "/Library/Application Support/Ventus/config.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else {
        logMessage("[Config] File not found at \(configPath)")
        return nil
    }

    do {
        let decoder = JSONDecoder()
        let config = try decoder.decode(Config.self, from: data)
        try config.validate()
        logMessage("[Config] Loaded successfully from \(configPath)")
        return config
    } catch {
        logMessage("[Config] Decode/validation failed: \(error), keeping last-good or using default")
        return nil
    }
}

func saveConfig(_ config: Config) {
    let configPath = "/Library/Application Support/Ventus/config.json"
    let dir = URL(fileURLWithPath: "/Library/Application Support/Ventus")

    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])

        let tempPath = configPath + ".tmp"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: URL(fileURLWithPath: tempPath))

        try? FileManager.default.removeItem(atPath: configPath)
        try FileManager.default.moveItem(atPath: tempPath, toPath: configPath)

        logMessage("[Config] Saved successfully to \(configPath)")
    } catch {
        logMessage("[Config] Save failed: \(error)")
    }
}

// MARK: - XPC Server Delegate

class VentusXPCServerDelegate: NSObject, NSXPCListenerDelegate {
    let controller: DaemonController

    init(controller: DaemonController) {
        self.controller = controller
    }

    /// Authorized iff the peer is root, its effective gid is the admin group, or
    /// its user is a member of the admin group. Fails closed on lookup failure.
    static func peerIsAuthorized(uid: uid_t, gid: gid_t) -> Bool {
        if uid == 0 { return true }
        guard let adminGroup = getgrnam("admin") else { return false }
        let adminGID = adminGroup.pointee.gr_gid
        if gid == adminGID { return true }
        // Check explicit membership list (gr_mem) for the peer's user name.
        guard let pw = getpwuid(uid), let namePtr = pw.pointee.pw_name else { return false }
        let peerName = String(cString: namePtr)
        var memPtr = adminGroup.pointee.gr_mem
        while let entry = memPtr?.pointee {
            if String(cString: entry) == peerName { return true }
            memPtr = memPtr?.advanced(by: 1)
        }
        // Also honor the user's primary gid being admin.
        return pw.pointee.pw_gid == adminGID
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        logMessage("[XPC] New connection attempt")

        // Authorize the CONNECTING PEER, not the daemon. effectiveUserIdentifier
        // is the peer's euid as seen by the kernel; getuid() here would be the
        // daemon's own (root) and authorize everyone.
        let peerUID = newConnection.effectiveUserIdentifier
        let peerGID = newConnection.effectiveGroupIdentifier
        if !Self.peerIsAuthorized(uid: peerUID, gid: peerGID) {
            logMessage("[XPC] REJECTED connection from uid=\(peerUID) gid=\(peerGID) (not root/admin)")
            return false
        }
        logMessage("[XPC] ACCEPTED connection from uid=\(peerUID)")

        let exportedObject = VentusXPCServiceImpl(controller: controller)
        newConnection.exportedInterface = NSXPCInterface(with: VentusXPCProtocol.self)
        newConnection.exportedObject = exportedObject

        newConnection.resume()
        return true
    }
}

// MARK: - XPC Service Implementation

class VentusXPCServiceImpl: NSObject, VentusXPCProtocol {
    let controller: DaemonController

    init(controller: DaemonController) {
        self.controller = controller
    }

    func getStatus(reply: @escaping (Data) -> Void) {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            if let data = self.controller.getStatusXPC() {
                reply(data)
            } else {
                let errorSnapshot = TelemetrySnapshot(
                    mode: "error",
                    activeProfile: "unknown",
                    activeRule: nil,
                    timestamp: Date(),
                    uptime: 0,
                    sensors: [],
                    fans: [],
                    packageWatts: nil,
                    explanations: [],
                    version: "1.0.0"
                )
                let encoder = JSONEncoder()
                if let data = try? encoder.encode(errorSnapshot) {
                    reply(data)
                }
            }
        }
    }

    func getConfig(reply: @escaping (Data) -> Void) {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            if let data = self.controller.getConfigXPC() {
                reply(data)
            }
        }
    }

    func setConfig(_ configData: Data, reply: @escaping (Data) -> Void) {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let result = self.controller.setConfigXPC(configData)
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(result) {
                reply(data)
            }
        }
    }

    func setProfile(_ profileName: String, reply: @escaping (Data) -> Void) {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let result = self.controller.setProfileXPC(profileName)
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(result) {
                reply(data)
            }
        }
    }

    func arm(reply: @escaping (Data) -> Void) {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let result = self.controller.armXPC()
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(result) {
                reply(data)
            }
        }
    }

    func disarm(reply: @escaping (Data) -> Void) {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let result = self.controller.disarmXPC()
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(result) {
                reply(data)
            }
        }
    }

    func setAppleAuto(reply: @escaping (Data) -> Void) {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let result = self.controller.setAppleAutoXPC()
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(result) {
                reply(data)
            }
        }
    }
}

// MARK: - Entry Point

// Install SIG_IGN before ANY other work so there is never a window where the
// default (terminate-without-cleanup) disposition is active. The dispatch
// sources set up later are the sole delivery path.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

let arguments = CommandLine.arguments
let dryRun = arguments.contains("--dry-run")
let restoreAutoFlag = arguments.contains("--restore-auto")

if restoreAutoFlag {
    logMessage("[Main] Restore-auto oneshot mode")
    guard let smc = SMCClient(logger: logMessage) else {
        logMessage("[Main] FAILED: cannot open SMC connection — fans may still be forced")
        exit(1)
    }
    // FNum can be unreadable; fall back to probing a fixed range. We must not
    // "succeed" having written nothing (the old bug that let uninstall delete
    // the daemon with fans still forced).
    let reported = smc.listFanCount()
    let fanRange = reported > 0 ? 0 ..< reported : 0 ..< 8
    var verifiedRestored = 0
    var anyFailure = false
    for i in fanRange {
        // A fan "exists" if we can read its mode at all.
        guard smc.readFanMode(i) != nil else { continue }
        smc.setFanMode(i, mode: 0)
        if let mode = smc.readFanMode(i), mode == 0 {
            verifiedRestored += 1
        } else {
            logMessage("[Main] VERIFY FAILED: F\(i)Md not 0 after restore")
            anyFailure = true
        }
    }
    if anyFailure || verifiedRestored == 0 {
        logMessage("[Main] Restore failed (verified=\(verifiedRestored), failure=\(anyFailure))")
        exit(1)
    }
    logMessage("[Main] Restored \(verifiedRestored) fan(s) to auto (verified)")
    exit(0)
}

logMessage("[Main] Starting with dryRun: \(dryRun)")

do {
    let controller = try DaemonController(dryRun: dryRun)
    logMessage("[Main] Calling controller.run()")
    controller.run()
    logMessage("[Main] controller.run() returned")
} catch {
    logMessage("[Fatal] Failed to initialize: \(error)")
    exit(1)
}
