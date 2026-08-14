import Foundation
@preconcurrency import VentusCore
import VentusIPC
import IOKit
import IOKit.pwr_mgt
import os.log

// From <IOKit/IOMessage.h> — not surfaced by the Swift IOKit module. Stable
// ABI values (iokit_common_msg(0x2xx/0x3xx)).
private let kVentusMessageCanSystemSleep: UInt32 = 0xE000_0270
private let kVentusMessageSystemWillSleep: UInt32 = 0xE000_0280
private let kVentusMessageSystemHasPoweredOn: UInt32 = 0xE000_0300

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

    struct SensorTemp: Codable, Sendable {
        let group: String
        let celsius: Double
    }

    struct Explanation: Codable, Sendable {
        let fan: Int
        let targetRPM: Double
        let winner: String
    }

    let mode: String  // "observe", "armed", or "monitor" (fanless Mac)
    let activeProfile: String
    let activeRule: String?
    let timestamp: Date
    let uptime: TimeInterval
    let sensors: [SensorInfo]
    let fans: [FanInfo]
    let packageWatts: Double?
    let explanations: [Explanation]
    let version: String
    /// False on fanless Macs (e.g. MacBook Air): the app is monitor-only there.
    /// Optional so older clients that omit it default to true (fan-equipped).
    var fanControlAvailable: Bool? = true
    /// Every individual sensor reading (per-tile die heat map). Optional so
    /// old client/daemon pairings keep decoding.
    var sensorTemps: [SensorTemp]? = nil
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
    /// Exclusive hardware owner — the ONLY path to SMC control writes.
    let hardwareOwner: HardwareOwner?
    /// Whether this Mac has controllable fans. False on fanless Macs (Air):
    /// the daemon then runs pure monitor mode — never arms, never writes SMC.
    /// Determined once at startup; sticky-true (any positive fan read wins).
    let fanControlAvailable: Bool

    /// FIX #5: published immutable telemetry. The control loop stores a fully
    /// formed snapshot here under `snapshotLock`; readers (getStatusXPC) copy it
    /// out. No live mutable collection is ever touched from two queues.
    private let snapshotLock = NSLock()
    private var publishedSnapshot: TelemetrySnapshot

    init(config: Config) throws {
        self.config = config
        self.armed = config.armed
        self.sensorReader = SensorReader(logger: logMessage)
        self.powerReader = PowerReader(logger: logMessage)
        let smc = SMCClient(logger: logMessage)
        self.smcClient = smc
        self.curveEngine = CurveEngine(logger: logMessage)
        self.ruleEngine = RuleEngine(logger: logMessage)
        self.supervisor = SafetySupervisor(armed: config.armed, logger: logMessage)
        self.heartbeatWatchdog = ControlLoopWatchdog(stallThresholdS: 10, logger: logMessage)
        self.cpuWatchdog = SelfCPUWatchdog(logger: logMessage)
        self.startTime = Date()
        self.hardwareOwner = smc.map { HardwareOwner(hardware: $0, logger: logMessage) }

        // Detect fan presence once at startup. Sticky-true across a few reads so a
        // transiently-zero FNum on a fan-equipped Mac doesn't mislabel it fanless.
        // A false negative is safe (monitor-only never writes); a false positive
        // would need FNum to read high on an Air, which it does not.
        var detectedFans = 0
        if let smc = smc {
            for _ in 0 ..< 3 { detectedFans = max(detectedFans, smc.listFanCount()) }
        }
        self.fanControlAvailable = detectedFans > 0

        self.publishedSnapshot = TelemetrySnapshot(
            mode: fanControlAvailable ? (config.armed ? "armed" : "observe") : "monitor",
            activeProfile: config.pinnedProfile ?? "balanced",
            activeRule: nil, timestamp: Date(), uptime: 0,
            sensors: [], fans: [], packageWatts: nil, explanations: [], version: "1.0.0",
            fanControlAvailable: fanControlAvailable
        )

        logMessage("[DaemonState] Initialized (fanControlAvailable: \(fanControlAvailable), fans: \(detectedFans), armed: \(config.armed))")
    }

    /// FIX #5: store a fully-formed snapshot (called only from the control loop).
    func publish(sensors: [SensorGroup: GroupReading],
                 sensorDetails: [(group: SensorGroup, celsius: Double)] = [],
                 power: PowerReader.PowerReading?,
                 fanActuals: [Int: Double],
                 explanations: [CurveEngine.Explanation],
                 activeRule: String?) {
        let sensorInfos = sensors.map {
            TelemetrySnapshot.SensorInfo(groupName: $0.key.rawValue, maxTemp: $0.value.max,
                                         meanTemp: $0.value.mean, count: $0.value.count)
        }
        let fanInfos = explanations.map {
            TelemetrySnapshot.FanInfo(fanIndex: $0.fan, actualRPM: fanActuals[$0.fan] ?? 0, targetRPM: $0.targetRPM)
        }
        let exps = explanations.map {
            TelemetrySnapshot.Explanation(fan: $0.fan, targetRPM: $0.targetRPM, winner: $0.winner)
        }
        let snap = TelemetrySnapshot(
            mode: fanControlAvailable ? (armed ? "armed" : "observe") : "monitor",
            activeProfile: config.pinnedProfile ?? "balanced",
            activeRule: activeRule, timestamp: Date(),
            uptime: Date().timeIntervalSince(startTime),
            sensors: sensorInfos, fans: fanInfos,
            packageWatts: power?.totalW, explanations: exps, version: "1.0.0",
            fanControlAvailable: fanControlAvailable,
            sensorTemps: sensorDetails.map {
                TelemetrySnapshot.SensorTemp(group: $0.group.rawValue, celsius: $0.celsius)
            }
        )
        snapshotLock.withLock { publishedSnapshot = snap }
    }

    /// FIX #5: readers get an immutable copy; they never touch live loop state.
    func getSnapshot() -> TelemetrySnapshot {
        snapshotLock.withLock { publishedSnapshot }
    }

    func setArmed(_ newArmed: Bool) {
        armed = newArmed
        config.armed = newArmed
        supervisor.setArmed(newArmed)
    }

    /// Verified release to Apple auto via the owner (no latch). Returns success.
    @discardableResult
    func restoreAuto(deadline: TimeInterval = 3) -> Bool {
        guard let owner = hardwareOwner else {
            logMessage("[DaemonState] restoreAuto: SMC unavailable, cannot restore")
            return false
        }
        let result = owner.submit(.restore, deadline: deadline)
        if result != .ok { logMessage("[DaemonState] restoreAuto result: \(result)") }
        return result == .ok
    }

    /// Latching emergency restore via the owner. After this, all normal control
    /// is refused until the process restarts. Returns success.
    @discardableResult
    func emergencyRestore(deadline: TimeInterval = 2) -> Bool {
        guard let owner = hardwareOwner else {
            logMessage("[DaemonState] emergencyRestore: SMC unavailable")
            return false
        }
        let result = owner.submit(.emergencyRestore, deadline: deadline)
        logMessage("[DaemonState] emergencyRestore result: \(result)")
        return result == .ok
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
    private var pendingRestore = false
    /// Audit C5/C8: consecutive armed-mode command failures (failed writes,
    /// owner-queue timeouts). The loop re-issues targets each tick so a
    /// transient failure self-heals; a persistent one means fans may be stuck
    /// at a stale forced target while heartbeats still look healthy — after
    /// this many in a row, emergency-restore and die (launchd restarts into
    /// startup restore with a fresh owner queue).
    private var consecutiveCommandFailures = 0
    private static let maxConsecutiveCommandFailures = 5
    /// Audit H3: frozen-sensor detection. Real sensors jitter every tick; a
    /// bit-identical full snapshot for this many consecutive armed ticks means
    /// the sensor pipeline is frozen and curves are flying blind.
    private var lastSensorSignature: [Double] = []
    private var frozenSensorTicks = 0
    /// Consecutive ticks with all critical sensor groups absent. A stale HID
    /// client (post-sleep, or a missed wake) reads empty for a beat after
    /// rebuild, so we reinit once, tolerate a short warm-up grace, and only
    /// treat it as a real failure (restore + disarm) once absence is SUSTAINED
    /// — never disarm armed mode on a single transient empty read.
    private var criticalAbsentTicks = 0
    private static let sensorFailureGraceTicks = 4   // ~ up to a few seconds
    private static let maxFrozenSensorTicks = 30
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

    // Audit H7: sleep/wake power management.
    private var powerConnection: io_connect_t = 0
    private var powerNotifier: IONotificationPortRef?
    private var powerNotifierObject: io_object_t = 0
    private let powerQueue = DispatchQueue(label: "com.formm.ventus.power")

    // Hardware ownership now lives entirely in state.hardwareOwner: it holds the
    // emergency latch and serializes all SMC writes on its own queue, so the
    // control loop, watchdog, and signal handler coordinate through submit() with
    // a deadline and never share a lock held across blocking I/O.

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

        // Startup restore runs whenever an SMC control surface exists — NOT
        // gated on fanControlAvailable: a transiently-zero fan-count probe at
        // boot must never skip restoring fans a previous run left forced
        // (restoreAllVerified probes fan slots itself when the count reads 0).
        if state.hardwareOwner != nil {
            logMessage("[Daemon] Performing startup restoreAuto (idempotent, safe when SMC unavailable)")
            var startupRestoreSucceeded = false
            for attempt in 1 ... 3 {
                if state.restoreAuto() {
                    startupRestoreSucceeded = true
                    break
                }
                logMessage("[Daemon] Startup restore attempt \(attempt)/3 failed")
                if attempt < 3 {
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
            if !startupRestoreSucceeded {
                logMessage("[Daemon] CRITICAL: startup restore failed")
                pendingRestore = true
            }
        } else {
            logMessage("[Daemon] Monitor-only mode: this Mac has no controllable fans")
        }

        // Register for sleep/wake before driving fans.
        setupPowerNotifications()

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

        if !state.armed, pendingRestore {
            if state.restoreAuto() {
                pendingRestore = false
                logMessage("[ControlLoop] Pending restore verified; fans are back in Apple auto")
            } else {
                logMessage("[ControlLoop] CRITICAL: pending restore retry failed")
            }
        }

        // Read hardware
        let (sensors, sensorDetails) = state.sensorReader.detailedSnapshot()
        let power = state.powerReader.readPower()
        let fanCount = state.smcClient?.listFanCount() ?? 2

        // FIX #7: Sensor failure detection — if cpuPerf+gpu+soc all absent, treat as failure
        let criticalGroupsMissing = !sensors.keys.contains(.cpuPerf)
            && !sensors.keys.contains(.gpu)
            && !sensors.keys.contains(.soc)

        if criticalGroupsMissing {
            criticalAbsentTicks += 1

            // First detection: a stale HID client (post-sleep / missed wake)
            // reads empty until rebuilt. Reinit ONCE and retry quickly before
            // treating it as failure — do NOT disarm on this transient.
            if criticalAbsentTicks == 1 {
                logMessage("[ControlLoop] critical sensors absent — reinitializing readers to attempt recovery")
                state.sensorReader.reinitialize()
                state.powerReader.reinitialize()
                return 1.0
            }
            // Warm-up grace: give the rebuilt client a few ticks to populate
            // before declaring a real failure. Still no disarm here.
            if criticalAbsentTicks < Self.sensorFailureGraceTicks {
                return 1.0
            }
            // Sustained absence → genuine sensor failure.
            logMessage("[ControlLoop] SENSOR FAILURE: critical groups absent for \(criticalAbsentTicks) ticks")
            if state.armed {
                logMessage("[ControlLoop] Armed during sustained sensor failure — restoring auto and entering observe")
                if state.restoreAuto() {
                    pendingRestore = false
                } else {
                    pendingRestore = true
                    logMessage("[ControlLoop] CRITICAL: sensor-failure restore failed")
                }
                state.setArmed(false)
                saveConfig(state.config)
            }
            // Rate-limit further rebuilds so a genuinely sensorless state doesn't
            // churn (and leak-free reinit stays cheap): retry ~every 10 ticks.
            if criticalAbsentTicks % 10 == 0 {
                state.sensorReader.reinitialize()
                state.powerReader.reinitialize()
            }
            return 5.0  // Return to cool tick, don't make decisions on missing sensors
        }
        criticalAbsentTicks = 0  // sensors present — reset the grace counter

        // Audit H3: frozen-sensor detection. A bit-identical full snapshot for
        // 30 consecutive armed ticks (~60s) means the pipeline is frozen — a
        // frozen-cool reading would hold fans low under real load. Same
        // response as sensor failure: restore, disarm, observe.
        let signature = sensorDetails.map(\.celsius)
        if signature == lastSensorSignature, !signature.isEmpty {
            frozenSensorTicks += 1
        } else {
            frozenSensorTicks = 0
            lastSensorSignature = signature
        }
        if state.armed, frozenSensorTicks >= Self.maxFrozenSensorTicks {
            logMessage("[ControlLoop] SENSOR FREEZE: \(frozenSensorTicks) identical snapshots — restoring auto and entering observe")
            if state.restoreAuto() {
                pendingRestore = false
            } else {
                pendingRestore = true
                logMessage("[ControlLoop] CRITICAL: sensor-freeze restore failed")
            }
            state.setArmed(false)
            saveConfig(state.config)
            frozenSensorTicks = 0
            return 5.0
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
            // Config validation makes this unreachable (pinned profile must
            // exist), but if it ever happens while armed the early return
            // below would freeze forced fans AND skip the thermal override —
            // so restore and disarm first, same as sensor failure.
            if state.armed {
                logMessage("[ControlLoop] Pinned profile '\(activeProfile)' missing while armed — restoring auto and entering observe")
                if !state.restoreAuto() {
                    logMessage("[ControlLoop] CRITICAL: missing-profile restore failed")
                }
                state.setArmed(false)
                saveConfig(state.config)
            }
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

        // FIX #4: explicit thermal decision, NOT an RPM>0 sentinel (a valid curve
        // may legitimately end at 0 RPM, which would alias with "no emergency").
        let decision = state.supervisor.thermalDecision(sensors: sensors, thermalState: thermalState)

        // Control writes only on Macs with fans. A fanless Mac (Air) is monitor
        // only: it publishes telemetry below but NEVER issues a control command.
        if state.fanControlAvailable, state.armed, let owner = state.hardwareOwner {
            let command: HardwareOwner.Command
            switch decision {
            case .forceMax:
                // Emergency wins unconditionally, even for a curve-less profile.
                command = .forceMaxAll
            case .normal:
                if profile.curves.isEmpty {
                    command = .restore   // auto-apple: release to macOS
                } else {
                    command = .apply(explanations.map { .init(fan: $0.fan, rpm: $0.targetRPM) })
                }
            }
            let result = owner.submit(command, deadline: 1.0)
            switch result {
            case .ok, .noHardware:
                consecutiveCommandFailures = 0
            case .refusedLatched:
                // The owner has emergency-latched: no normal control is
                // possible until restart. Stop pretending to drive.
                logMessage("[ControlLoop] owner latched — entering observe")
                state.setArmed(false)
                saveConfig(state.config)
            case .failed(let why):
                consecutiveCommandFailures += 1
                logMessage("[ControlLoop] hardware command failed (\(consecutiveCommandFailures) consecutive): \(why)")
            case .timedOut:
                consecutiveCommandFailures += 1
                logMessage("[ControlLoop] hardware command timed out (\(consecutiveCommandFailures) consecutive)")
            }

            if consecutiveCommandFailures >= Self.maxConsecutiveCommandFailures {
                // Fans may be stuck at a stale forced target (partial writes,
                // wedged owner queue) while heartbeats look healthy. Restore
                // if possible, then die — restart is the reliable reset.
                logMessage("[ControlLoop] CRITICAL: \(consecutiveCommandFailures) consecutive command failures — emergency restore + exit")
                state.emergencyRestore()
                exit(1)
            }
        }

        // FIX #5: publish an immutable snapshot; readers never touch live state.
        state.publish(sensors: sensors, sensorDetails: sensorDetails, power: power, fanActuals: fanActuals,
                      explanations: explanations, activeRule: nil)

        return state.curveEngine.suggestedTickS
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

            // Check control loop heartbeat. emergencyRestore is deadline-bounded
            // via the owner; whether or not it verifies in time, we ALWAYS exit —
            // death drops our forced-mode claim and launchd restarts us into the
            // startup restore. That die-and-restart is the always-available backstop.
            if state.heartbeatWatchdog.isStalled(now: now) {
                let stallTime = state.heartbeatWatchdog.secondsSinceHeartbeat(now: now)
                logMessage("[Watchdog] Control loop stalled \(String(format: "%.1f", stallTime))s — emergency restore + exit")
                state.emergencyRestore()
                exit(1)
            }

            // Check self-CPU usage
            if state.cpuWatchdog.isHighCPU(now: now) {
                let cpuPercent = state.cpuWatchdog.measureCPUPercent(now: now)
                logMessage("[Watchdog] Self-CPU high (\(String(format: "%.1f", cpuPercent * 100))%) — emergency restore + exit")
                state.emergencyRestore()
                exit(1)
            }
        }
    }

    // MARK: - Signal Handlers

    /// Audit H7: register for system sleep/wake. On will-sleep we restore fans
    /// to Apple auto and release the power assertion — never hold a forced
    /// target through an uncontrolled sleep where the control loop is frozen.
    /// The in-memory `armed` flag is preserved, so on wake the control loop's
    /// next tick re-establishes forced control automatically. SMC forced-fan
    /// state across sleep on Apple Silicon is undocumented; restoring first is
    /// the safe assumption either way.
    private func setupPowerNotifications() {
        var notifier: IONotificationPortRef?
        var notifierObject: io_object_t = 0
        let context = Unmanaged.passUnretained(self).toOpaque()
        let connection = IORegisterForSystemPower(context, &notifier, { refcon, _, messageType, argument in
            guard let refcon else { return }
            let controller = Unmanaged<DaemonController>.fromOpaque(refcon).takeUnretainedValue()
            controller.handlePowerMessage(type: messageType, argument: argument)
        }, &notifierObject)

        guard connection != MACH_PORT_NULL, let notifier else {
            logMessage("[Power] IORegisterForSystemPower failed — sleep/wake handling inactive")
            return
        }
        self.powerConnection = connection
        self.powerNotifier = notifier
        self.powerNotifierObject = notifierObject
        IONotificationPortSetDispatchQueue(notifier, powerQueue)
        logMessage("[Power] Registered for sleep/wake notifications")
    }

    private func handlePowerMessage(type: UInt32, argument: UnsafeMutableRawPointer?) {
        switch type {
        case kVentusMessageSystemWillSleep:
            // Restore to Apple auto so fans aren't stuck forced through sleep,
            // then allow the sleep (must not block or the system stalls ~30s).
            if state.armed {
                logMessage("[Power] System will sleep — restoring fans to Apple auto (armed flag preserved)")
                _ = state.restoreAuto(deadline: 2)
            }
            IOAllowPowerChange(powerConnection, Int(bitPattern: argument))
        case kVentusMessageCanSystemSleep:
            // We never veto sleep.
            IOAllowPowerChange(powerConnection, Int(bitPattern: argument))
        case kVentusMessageSystemHasPoweredOn:
            // The IOHID sensor client and the IOReport power subscription go
            // STALE across sleep — after wake, reads return nothing and temp
            // detection dies until the reader is rebuilt. Force both to
            // reinitialize; the control loop's next tick rebuilds the handles
            // and re-issues forced targets if still armed.
            logMessage("[Power] System woke — reinitializing sensor + power readers")
            state.sensorReader.reinitialize()
            state.powerReader.reinitialize()
            // Belt-and-braces: the watchdog already measures staleness on the
            // sleep-excluding uptime clock, but stamp a fresh heartbeat anyway
            // so the first post-wake tick can never be judged against a
            // pre-sleep timestamp while the control-loop timer respins.
            state.heartbeatWatchdog.recordHeartbeat()
        default:
            break
        }
    }

    private func setupSignalHandlers() {
        // Signal sources live on signalQueue (NOT serialQueue): a stalled control
        // loop must never delay SIGTERM cleanup. Replace the minimal init-time
        // handlers with ignored dispositions before activating dispatch sources.
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
        logMessage("[Signal] Caught SIGTERM/SIGINT — emergency restore + exit")
        state.emergencyRestore()
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
        // Same serialization discipline as the mutating endpoints: config is
        // read under serialQueue so a concurrent setConfig can't race the read.
        serialQueue.sync {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try? encoder.encode(state.config)
        }
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
            guard state.fanControlAvailable else {
                return .error("This Mac has no controllable fans — Ventus is monitor-only here.")
            }
            guard state.hardwareOwner?.isLatched != true else {
                return .error("Cannot arm: daemon is in emergency-stop state (restart required)")
            }
            state.setArmed(true)
            saveConfig(state.config)
            logMessage("[XPC] Armed mode enabled")
            return .ok()
        }
    }

    func disarmXPC() -> XPCResult {
        serialQueue.sync {
            // Clear armed FIRST so no tick issues new control, then verify-restore
            // through the owner and return the REAL result (finding #3).
            state.setArmed(false)
            let ok = state.restoreAuto()
            saveConfig(state.config)
            if ok {
                logMessage("[XPC] Disarmed; fans verified back to auto")
                return .ok()
            }
            logMessage("[XPC] Disarm: fan restore did NOT verify")
            return .error("Disarmed, but fans could not be verified back to auto — check daemon log")
        }
    }

    func setAppleAutoXPC() -> XPCResult {
        serialQueue.sync {
            state.setArmed(false)
            let ok = state.restoreAuto()
            saveConfig(state.config)
            if ok {
                logMessage("[XPC] Fans verified back to Apple auto")
                return .ok()
            }
            return .error("Could not verify fans back to Apple auto — check daemon log")
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
        let (sensors, sensorDetails) = state.sensorReader.detailedSnapshot()
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

        // Publish snapshot (dry-run performs NO SMC writes).
        state.publish(sensors: sensors, sensorDetails: sensorDetails, power: power, fanActuals: fanActuals,
                      explanations: explanations, activeRule: nil)
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

// No fans are forced before runDaemon(), so immediate _exit during init is safe.
signal(SIGTERM) { _ in _exit(0) }
signal(SIGINT) { _ in _exit(0) }

let arguments = CommandLine.arguments
let dryRun = arguments.contains("--dry-run")
let restoreAutoFlag = arguments.contains("--restore-auto")

if restoreAutoFlag {
    logMessage("[Main] Restore-auto oneshot mode")
    guard let smc = SMCClient(logger: logMessage) else {
        logMessage("[Main] FAILED: cannot open SMC connection — fans may still be forced")
        exit(1)
    }
    let owner = HardwareOwner(hardware: smc, logger: logMessage)
    let result = owner.submit(.restore, deadline: 3)
    logMessage("[Main] Restore-auto result: \(result)")
    if result == .ok {
        exit(0)
    }
    exit(1)
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
