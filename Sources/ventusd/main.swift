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
        guard let smc = smcClient else { return }
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

        // Write to SMC only if armed AND no thermal override
        if state.armed && safetyRPM == 0 {
            for explanation in explanations {
                let targetRPM = Float(explanation.targetRPM)
                state.smcClient?.setFanMode(explanation.fan, mode: 1)  // 1 = forced
                state.smcClient?.setFanTarget(explanation.fan, rpm: targetRPM)
            }
        } else if safetyRPM > 0 && state.armed {
            // Thermal override: force all fans to max
            for i in 0 ..< fanCount {
                state.smcClient?.setFanMode(i, mode: 1)
                state.smcClient?.setFanTarget(i, rpm: Float(safetyRPM))
            }
        }

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
                logMessage("[Watchdog] CONTROL LOOP STALLED for \(String(format: "%.1f", stallTime))s — restoring auto and exiting")
                state.restoreAuto()
                exit(1)
            }

            // Check self-CPU usage
            if state.cpuWatchdog.isHighCPU(now: now) {
                let cpuPercent = state.cpuWatchdog.measureCPUPercent(now: now)
                logMessage("[Watchdog] SELF-CPU HIGH (\(String(format: "%.1f", cpuPercent * 100))%) — restoring auto and exiting")
                state.restoreAuto()
                exit(1)
            }
        }
    }

    // MARK: - Signal Handlers

    private func setupSignalHandlers() {
        let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: serialQueue)
        let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: serialQueue)

        sigTermSource.setEventHandler { [weak self] in
            self?.handleSignal()
        }

        sigIntSource.setEventHandler { [weak self] in
            self?.handleSignal()
        }

        sigTermSource.resume()
        sigIntSource.resume()

        signal(SIGTERM, SIG_DFL)
        signal(SIGINT, SIG_DFL)
    }

    private func handleSignal() {
        logMessage("[Signal] Caught SIGTERM/SIGINT — restoring auto and exiting")
        shouldKeepRunning = false
        state.restoreAuto()
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

    func setConfigXPC(_ configData: Data) -> XPCResult {
        do {
            let decoder = JSONDecoder()
            let newConfig = try decoder.decode(Config.self, from: configData)
            try newConfig.validate()

            // Preserve armed state if already set
            let wasArmed = state.armed
            state.setArmed(false)  // Temporarily disarm for config update
            state.config = newConfig
            saveConfig(newConfig)
            if wasArmed {
                state.setArmed(true)  // Restore armed state if it was set
            }

            logMessage("[XPC] Config updated via setConfig")
            return .ok()
        } catch {
            let errorMsg = "Config validation failed: \(error)"
            logMessage("[XPC] \(errorMsg)")
            return .error(errorMsg)
        }
    }

    func setProfileXPC(_ profileName: String) -> XPCResult {
        if state.config.profiles[profileName] != nil {
            state.config.pinnedProfile = profileName
            saveConfig(state.config)
            logMessage("[XPC] Profile pinned to \(profileName)")
            return .ok()
        } else {
            let errorMsg = "Profile '\(profileName)' not found"
            logMessage("[XPC] \(errorMsg)")
            return .error(errorMsg)
        }
    }

    func armXPC() -> XPCResult {
        state.setArmed(true)
        saveConfig(state.config)
        logMessage("[XPC] Armed mode enabled")
        return .ok()
    }

    func disarmXPC() -> XPCResult {
        state.setArmed(false)
        saveConfig(state.config)
        state.restoreAuto()
        logMessage("[XPC] Disarmed mode enabled")
        return .ok()
    }

    func setAppleAutoXPC() -> XPCResult {
        state.restoreAuto()
        state.setArmed(false)
        saveConfig(state.config)
        logMessage("[XPC] Fans restored to Apple auto")
        return .ok()
    }

    private func runDryRun() {
        logMessage("[DryRun] Starting foreground observe mode")
        print("Ventus Daemon v1.0.0 (--dry-run mode)")
        print("Press Ctrl-C to exit\n")
        fflush(stdout)

        for tickCount in 0 ..< 5 {
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

        logMessage("[DryRun] 5 ticks complete, exiting")
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

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        logMessage("[XPC] New connection attempt")

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

let arguments = CommandLine.arguments
let dryRun = arguments.contains("--dry-run")
let restoreAuto = arguments.contains("--restore-auto")

if restoreAuto {
    logMessage("[Main] Restore-auto oneshot mode")
    if let smc = SMCClient(logger: logMessage) {
        let fanCount = smc.listFanCount()
        for i in 0 ..< fanCount {
            smc.setFanMode(i, mode: 0)
        }
        logMessage("[Main] Restored all fans to auto mode")
    }
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
