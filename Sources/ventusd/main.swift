import Foundation
import VentusCore
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

class DaemonState {
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
        // TODO: Implement full daemon with control loop, timers, and XPC server
        logMessage("[Daemon] Normal daemon mode not yet implemented")
    }

    private func runDryRun() {
        logMessage("[DryRun] Starting foreground observe mode")
        print("Ventus Daemon v1.0.0 (--dry-run mode)")
        print("Press Ctrl-C to exit\n")
        fflush(stdout)

        for tickCount in 0 ..< 5 {
            let telemetry = controlStep()

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

    private func controlStep() -> TelemetrySnapshot {
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
        let activeRule: String? = nil

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

        // Update state snapshot
        state.lastSensorSnapshot = sensors
        state.lastPowerReading = power
        state.lastFanActuals = fanActuals
        state.lastExplanations = explanations
        state.lastActiveRule = activeRule

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
