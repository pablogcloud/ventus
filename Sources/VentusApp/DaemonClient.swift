import Combine
import Foundation
import VentusCore
import os.log

let appLog = Logger(subsystem: "com.formm.ventus.app", category: "client")

// Debug builds only: also write to a readable file (os_log isn't captured for
// this ad-hoc app). Release builds ship with this compiled to a no-op.
enum DebugFile {
    #if DEBUG
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("ventus-app-debug.log")
    #endif

    static func write(_ s: String) {
        #if DEBUG
        let line = "\(Date().timeIntervalSince1970) \(s)\n"
        guard let d = line.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); try? fh.write(contentsOf: d); try? fh.close()
        } else {
            try? d.write(to: url)
        }
        #endif
    }
}

// MARK: - Local XPC Protocol Redeclaration

@objc protocol VentusXPCProtocol {
    func getStatus(reply: @escaping (Data) -> Void)
    func getConfig(reply: @escaping (Data) -> Void)
    func setConfig(_ configData: Data, reply: @escaping (Data) -> Void)
    func setProfile(_ profileName: String, reply: @escaping (Data) -> Void)
    func arm(reply: @escaping (Data) -> Void)
    func disarm(reply: @escaping (Data) -> Void)
    func setAppleAuto(reply: @escaping (Data) -> Void)
}

struct XPCResult: Codable {
    let success: Bool
    let error: String?
    let data: String?
}

// MARK: - Observable Daemon State

@MainActor
final class DaemonClientObserver: NSObject, ObservableObject {
    @Published var status: TelemetrySnapshot?
    @Published var isConnected = false
    @Published var config: Config?
    @Published var errorMessage: String?

    private var client: DaemonClient?

    override init() {
        super.init()
        setupClient()
    }

    private func setupClient() {
        client = DaemonClient(observer: self)
        Task {
            await client?.connect()
            await client?.startPolling()
        }
    }

    func updateStatus(_ status: TelemetrySnapshot) {
        // Monotonic: never let an OLDER snapshot overwrite a newer one. A poll
        // whose XPC call started before a control mutation can complete after
        // the mutation's own status apply; without this guard its late,
        // pre-mutation snapshot would clobber the fresh one and briefly flash
        // the previous profile (Grok residual-race finding). timestamp is
        // daemon-stamped per publish.
        if let current = self.status, status.timestamp < current.timestamp { return }
        self.status = status
        errorMessage = nil
    }

    func updateConfig(_ config: Config) {
        self.config = config
    }

    func setError(_ message: String?) {
        errorMessage = message
    }

    func setConnected(_ connected: Bool) {
        isConnected = connected
    }

    func clearStatus() {
        status = nil
    }

    func setProfile(_ profileName: String) async -> Bool {
        DebugFile.write("setProfile \(profileName) called")
        guard status?.isFanControlAvailable ?? true else {
            appLog.log("setProfile blocked: fanControl unavailable"); return false
        }
        guard let client else { appLog.log("setProfile: no client"); return false }
        let ok = await client.setProfile(profileName)
        if let snap = await client.getStatus() { updateStatus(snap) }   // apply synchronously (monotonic) so observer.status is current before we return
        appLog.log("observer.setProfile result=\(ok)")
        return ok
    }

    func arm() async -> Bool {
        DebugFile.write("arm called")
        guard status?.isFanControlAvailable ?? true else {
            appLog.log("arm blocked: fanControl unavailable"); return false
        }
        guard let client else { appLog.log("arm: no client"); return false }
        let ok = await client.arm()
        if let snap = await client.getStatus() { updateStatus(snap) }   // apply synchronously (monotonic) so observer.status is current before we return
        appLog.log("observer.arm result=\(ok)")
        return ok
    }

    func disarm() async -> Bool {
        guard let client else { return false }
        let ok = await client.disarm()
        if let snap = await client.getStatus() { updateStatus(snap) }
        return ok
    }

    func setAppleAuto() async -> Bool {
        guard status?.isFanControlAvailable ?? true else { return false }
        guard let client else { return false }
        let ok = await client.setAppleAuto()
        if let snap = await client.getStatus() { updateStatus(snap) }
        return ok
    }

    func setConfig(_ config: Config) async -> Bool {
        guard status?.isFanControlAvailable ?? true else { return false }
        guard let client else { return false }
        return await client.setConfig(config)
    }
}

// MARK: - XPC Connection Manager

actor DaemonClient {
    nonisolated(unsafe) private weak var observer: DaemonClientObserver?
    private var connection: NSXPCConnection?
    private let serviceName = "com.formm.ventus.daemon"
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    init(observer: DaemonClientObserver) {
        self.observer = observer
    }

    nonisolated private func updateObserver(
        action: @MainActor @escaping (DaemonClientObserver) -> Void
    ) {
        guard let observer else { return }
        Task { @MainActor in
            action(observer)
        }
    }

    func connect() async {
        let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: VentusXPCProtocol.self)
        connection.invalidationHandler = { [weak self] in
            Task { await self?.handleDisconnection() }
        }
        connection.interruptionHandler = { [weak self] in
            Task { await self?.handleDisconnection() }
        }
        connection.resume()
        self.connection = connection

        // Confirm the connection actually works before declaring it up: a
        // resumed NSXPCConnection to a dead service still "succeeds" until the
        // first call fails.
        if let status = await getStatus() {
            reconnectAttempts = 0   // healthy — reset the backoff counter
            updateObserver {
                $0.setConnected(true)
                $0.setError(nil)
            }
            _ = await getConfig()
            _ = status
        } else {
            await handleDisconnection()
        }
    }

    private func handleDisconnection() async {
        updateObserver {
            $0.setConnected(false)
            $0.clearStatus()
        }

        // Local daemon: NEVER give up permanently — the daemon can be restarted
        // (reinstall, crash-recovery) at any time and the app must self-heal
        // whenever it comes back. Back off up to a cap, then keep retrying at
        // that cap forever. (The old code stopped after 5 tries AND never reset
        // the counter on success, so a few daemon restarts wedged the app until
        // relaunch.)
        connection?.invalidate()
        connection = nil
        reconnectAttempts += 1
        let backoffSeconds = min(pow(2.0, Double(reconnectAttempts)), 8.0)
        if reconnectAttempts == maxReconnectAttempts {
            updateObserver {
                $0.setError("Waiting for the Ventus daemon… (retrying)")
            }
        }
        try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
        await connect()
    }

    func getStatus() async -> TelemetrySnapshot? {
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            appLog.log("getStatus XPC ERROR: \(error.localizedDescription, privacy: .public)")
            self?.updateObserver {
                $0.setError("Connection error: \(error.localizedDescription)")
            }
        }) as? VentusXPCProtocol else {
            appLog.log("getStatus: no proxy (connection nil)")
            return nil
        }

        return await withCheckedContinuation { continuation in
            proxy.getStatus { [weak self] data in
                do {
                    let snapshot = try JSONDecoder().decode(TelemetrySnapshot.self, from: data)
                    DebugFile.write("poll mode=\(snapshot.mode) profile=\(snapshot.activeProfile) fanCtl=\(snapshot.isFanControlAvailable)")
                    self?.updateObserver { $0.updateStatus(snapshot) }
                    continuation.resume(returning: snapshot)
                } catch {
                    appLog.log("poll: DECODE ERROR \(String(describing: error), privacy: .public)")
                    self?.updateObserver { $0.setError("Decode error: \(error)") }
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func getConfig() async -> Config? {
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in })
            as? VentusXPCProtocol
        else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            proxy.getConfig { [weak self] data in
                do {
                    let config = try JSONDecoder().decode(Config.self, from: data)
                    self?.updateObserver { $0.updateConfig(config) }
                    continuation.resume(returning: config)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func setConfig(_ config: Config) async -> Bool {
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in })
            as? VentusXPCProtocol
        else {
            return false
        }

        do {
            let data = try JSONEncoder().encode(config)
            return await withCheckedContinuation { continuation in
                proxy.setConfig(data) { resultData in
                    do {
                        let result = try JSONDecoder().decode(XPCResult.self, from: resultData)
                        continuation.resume(returning: result.success)
                    } catch {
                        continuation.resume(returning: false)
                    }
                }
            }
        } catch {
            return false
        }
    }

    /// Resumes a continuation exactly once even if both the XPC reply and the
    /// connection error handler fire.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func tryFire() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    /// One control call whose continuation is GUARANTEED to resume: XPC invokes
    /// either the reply block or the connection error handler — the previous
    /// per-method pattern ignored the error handler, so a dropped connection
    /// leaked the continuation and stalled the app's control-transaction chain
    /// forever.
    private func controlCall(
        _ invoke: (VentusXPCProtocol, @escaping (Data) -> Void) -> Void
    ) async -> Bool {
        let once = OnceFlag()
        return await withCheckedContinuation { continuation in
            guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in
                if once.tryFire() { continuation.resume(returning: false) }
            }) as? VentusXPCProtocol else {
                if once.tryFire() { continuation.resume(returning: false) }
                return
            }
            invoke(proxy) { resultData in
                guard once.tryFire() else { return }
                let success = (try? JSONDecoder().decode(XPCResult.self, from: resultData))?
                    .success ?? false
                continuation.resume(returning: success)
            }
        }
    }

    func setProfile(_ profileName: String) async -> Bool {
        await controlCall { proxy, reply in proxy.setProfile(profileName, reply: reply) }
    }

    func arm() async -> Bool {
        await controlCall { proxy, reply in proxy.arm(reply: reply) }
    }

    func disarm() async -> Bool {
        await controlCall { proxy, reply in proxy.disarm(reply: reply) }
    }

    func setAppleAuto() async -> Bool {
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in })
            as? VentusXPCProtocol
        else {
            return false
        }

        return await withCheckedContinuation { continuation in
            proxy.setAppleAuto { resultData in
                do {
                    let result = try JSONDecoder().decode(XPCResult.self, from: resultData)
                    continuation.resume(returning: result.success)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private var pollTask: Task<Void, Never>?

    func startPolling() {
        // An async sleep loop, NOT Timer.scheduledTimer: this actor's executor has
        // no run loop, so scheduled timers would never fire (the poll was dead —
        // the UI froze on the first snapshot and never saw arm/disarm take effect).
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // A nil poll with a live connection object means the proxy
                // failed without the invalidation handler firing (daemon gone).
                // Kick a reconnect so the app recovers even then.
                if await self?.getStatus() == nil, await self?.hasConnection == true {
                    await self?.handleDisconnection()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    var hasConnection: Bool { connection != nil }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}

// MARK: - Telemetry Serialization

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

    let mode: String
    let activeProfile: String
    let activeRule: String?
    let timestamp: Date
    let uptime: TimeInterval
    let sensors: [SensorInfo]
    let fans: [FanInfo]
    let packageWatts: Double?
    let explanations: [Explanation]
    let version: String
    let fanControlAvailable: Bool?
    /// Individual sensor readings (per-tile die heat map). Optional: older
    /// daemons don't send it.
    var sensorTemps: [SensorTemp]? = nil

    struct SensorTemp: Codable, Sendable {
        let group: String
        let celsius: Double
    }

    var isFanControlAvailable: Bool {
        fanControlAvailable ?? true
    }
}

extension TelemetrySnapshot {
    /// Headline temperature for a group: the GROUP MEAN, because that is the
    /// value the daemon's curve engine actually blends to drive the fans
    /// (CurveEngine.updateEMA uses GroupReading.mean). Showing the group max
    /// here made the panel/dashboard disagree with the menu bar (which shows
    /// the mean) — the same "CPU" label reporting two different numbers — and
    /// made the reading jump on transient single-sensor spikes.
    func temperature(for groupName: String) -> Double? {
        sensors.first { $0.groupName == groupName }?.meanTemp
    }

    /// Hottest individual reading WITHIN one group. Use for anything
    /// safety-relevant: the daemon's 95C override triggers on the hottest
    /// sensor, so status indicators must track this, not the mean.
    func peakTemperature(for groupName: String) -> Double? {
        sensors.first { $0.groupName == groupName }?.maxTemp
    }

    /// Hottest INDIVIDUAL reading across all groups. Only for surfaces that
    /// explicitly say "peak"; never mix this with the headline numbers above.
    var hottestTemperature: Double? {
        sensors.map(\.maxTemp).max()
    }

    /// All individual readings for a sensor group (empty when the daemon
    /// predates per-sensor telemetry).
    func temps(for groupName: String) -> [Double] {
        sensorTemps?.filter { $0.group == groupName }.map(\.celsius) ?? []
    }
}
