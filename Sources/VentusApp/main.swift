import SwiftUI
import Foundation
import VentusCore
import Combine

// MARK: - Local XPC Protocol Redeclaration (workaround for VentusIPC visibility)

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

// MARK: - App Entry Point

@main
struct VentusApp: App {
    @StateObject private var daemonClient = DaemonClientObserver()
    @State private var showMainWindow = false

    var body: some Scene {
        MenuBarExtra("--°", systemImage: "fan.circle") {
            PopoverView(observer: daemonClient, showMainWindow: $showMainWindow)
        }

        Window("Ventus", id: "mainWindow") {
            MainWindowView(observer: daemonClient)
        }
        .keyboardShortcut("1", modifiers: .command)
    }
}

// MARK: - Observable Wrapper for Daemon State

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
        self.status = status
        self.errorMessage = nil
    }

    func updateConfig(_ config: Config) {
        self.config = config
    }

    func setError(_ message: String) {
        self.errorMessage = message
    }

    func setConnected(_ connected: Bool) {
        self.isConnected = connected
    }

    func clearStatus() {
        self.status = nil
    }

    func setProfile(_ profileName: String) async -> Bool {
        guard let client = client else { return false }
        return await client.setProfile(profileName)
    }

    func arm() async -> Bool {
        guard let client = client else { return false }
        return await client.arm()
    }

    func disarm() async -> Bool {
        guard let client = client else { return false }
        return await client.disarm()
    }

    func setAppleAuto() async -> Bool {
        guard let client = client else { return false }
        return await client.setAppleAuto()
    }

    func setConfig(_ config: Config) async -> Bool {
        guard let client = client else { return false }
        return await client.setConfig(config)
    }
}

// MARK: - Daemon Client (XPC Connection Manager)

actor DaemonClient {
    nonisolated(unsafe) private weak var observer: DaemonClientObserver?
    private var connection: NSXPCConnection?
    private let serviceName = "com.formm.ventus.daemon"
    private var pollTimer: Timer?
    private var backgroundPollTimer: Timer?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    init(observer: DaemonClientObserver) {
        self.observer = observer
    }

    nonisolated private func updateObserver(action: @MainActor @escaping (DaemonClientObserver) -> Void) {
        guard let observer = observer else { return }
        Task { @MainActor in
            action(observer)
        }
    }

    // MARK: Connection Management

    func connect() async {
        let conn = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: VentusXPCProtocol.self)

        conn.invalidationHandler = { [weak self] in
            Task {
                await self?.handleDisconnection()
            }
        }

        conn.interruptionHandler = { [weak self] in
            Task {
                await self?.handleDisconnection()
            }
        }

        conn.resume()
        self.connection = conn

        updateObserver { $0.setConnected(true) }

        // Load initial status and config
        _ = await getStatus()
        _ = await getConfig()
    }

    private func handleDisconnection() async {
        updateObserver { observer in
            observer.setConnected(false)
            observer.clearStatus()
        }

        reconnectAttempts += 1
        guard reconnectAttempts < maxReconnectAttempts else {
            updateObserver { $0.setError("Failed to connect to daemon. Please ensure ventusd is running.") }
            return
        }

        let backoffSeconds = pow(2.0, Double(reconnectAttempts))
        try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))

        if reconnectAttempts < maxReconnectAttempts {
            await connect()
        }
    }

    // MARK: XPC Calls

    func getStatus() async -> TelemetrySnapshot? {
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.updateObserver { $0.setError("Connection error: \(error.localizedDescription)") }
        }) as? VentusXPCProtocol else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            proxy.getStatus { [weak self] data in
                do {
                    let snapshot = try JSONDecoder().decode(TelemetrySnapshot.self, from: data)
                    self?.updateObserver { $0.updateStatus(snapshot) }
                    continuation.resume(returning: snapshot)
                } catch {
                    self?.updateObserver { $0.setError("Decode error: \(error)") }
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func getConfig() async -> Config? {
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? VentusXPCProtocol else {
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
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? VentusXPCProtocol else {
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

    func setProfile(_ profileName: String) async -> Bool {
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? VentusXPCProtocol else {
            return false
        }

        return await withCheckedContinuation { continuation in
            proxy.setProfile(profileName) { resultData in
                do {
                    let result = try JSONDecoder().decode(XPCResult.self, from: resultData)
                    continuation.resume(returning: result.success)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func arm() async -> Bool {
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? VentusXPCProtocol else {
            return false
        }

        return await withCheckedContinuation { continuation in
            proxy.arm { resultData in
                do {
                    let result = try JSONDecoder().decode(XPCResult.self, from: resultData)
                    continuation.resume(returning: result.success)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func disarm() async -> Bool {
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? VentusXPCProtocol else {
            return false
        }

        return await withCheckedContinuation { continuation in
            proxy.disarm { resultData in
                do {
                    let result = try JSONDecoder().decode(XPCResult.self, from: resultData)
                    continuation.resume(returning: result.success)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func setAppleAuto() async -> Bool {
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? VentusXPCProtocol else {
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

    // MARK: Polling

    func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task {
                _ = await self?.getStatus()
            }
        }

        backgroundPollTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task {
                _ = await self?.getStatus()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        backgroundPollTimer?.invalidate()
    }
}

// MARK: - Popover View

struct PopoverView: View {
    @ObservedObject var observer: DaemonClientObserver
    @Binding var showMainWindow: Bool
    @State private var showArmConfirmation = false

    var body: some View {
        VStack(spacing: 12) {
            if let status = observer.status {
                // Temperature readings
                VStack(alignment: .leading, spacing: 8) {
                    Text("Temperatures").font(.headline)

                    ForEach(status.sensors, id: \.groupName) { sensor in
                        HStack {
                            Text(sensor.groupName.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.0f°C", sensor.maxTemp))
                                .font(.caption).monospacedDigit()
                        }
                    }
                }
                .padding(.vertical, 8)

                Divider()

                // Fan info
                VStack(alignment: .leading, spacing: 6) {
                    Text("Fans").font(.headline)

                    ForEach(status.fans, id: \.fanIndex) { fan in
                        HStack {
                            Text("Fan \(fan.fanIndex)")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.0f → %.0f RPM", fan.actualRPM, fan.targetRPM))
                                .font(.caption).monospacedDigit()
                        }
                    }
                }
                .padding(.vertical, 8)

                Divider()

                // Power
                if let watts = status.packageWatts {
                    HStack {
                        Text("Power")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.1f W", watts))
                            .font(.caption).monospacedDigit()
                    }
                    .padding(.vertical, 8)

                    Divider()
                }

                // Mode and profile
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Mode")
                                .font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            Text(status.mode.uppercased())
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(status.mode == "armed" ? Color.orange : Color.gray)
                                .foregroundColor(.white)
                                .cornerRadius(4)
                        }

                        HStack {
                            Text("Profile")
                                .font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            Text(status.activeProfile)
                                .font(.caption2)
                        }
                    }
                }
                .padding(.vertical, 8)

                Divider()

                // Controls
                VStack(spacing: 8) {
                    Button(action: {
                        if status.mode == "armed" {
                            Task {
                                _ = await observer.disarm()
                            }
                        } else {
                            showArmConfirmation = true
                        }
                    }) {
                        HStack {
                            Spacer()
                            Text(status.mode == "armed" ? "Disarm Fan Control" : "Arm Fan Control")
                            Spacer()
                        }
                    }
                    .buttonStyle(.bordered)

                    if status.mode == "armed" {
                        Button(action: {
                            Task {
                                _ = await observer.setAppleAuto()
                            }
                        }) {
                            HStack {
                                Spacer()
                                Text("Apple Auto")
                                Spacer()
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    Button(action: {
                        NSApp.activate(ignoringOtherApps: true)
                        showMainWindow = true
                    }) {
                        HStack {
                            Spacer()
                            Text("Open Ventus…")
                            Spacer()
                        }
                    }
                    .buttonStyle(.bordered)
                }

            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundColor(.yellow)

                    Text("Daemon Unreachable")
                        .font(.headline)

                    Text("The Ventus daemon (ventusd) is not running. Fans remain on Apple auto.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: {
                        NSApp.activate(ignoringOtherApps: true)
                        showMainWindow = true
                    }) {
                        Text("Install/Start Daemon")
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
        }
        .padding(12)
        .frame(width: 280)
        .alert("Confirm Armed Mode", isPresented: $showArmConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Arm Fans", role: .destructive) {
                Task {
                    _ = await observer.arm()
                }
            }
        } message: {
            Text("Fan writes will become live. Any errors will revert to Apple auto.")
        }
    }
}

// MARK: - Main Window View

struct MainWindowView: View {
    @ObservedObject var observer: DaemonClientObserver
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardTabView(observer: observer)
                .tabItem {
                    Label("Dashboard", systemImage: "gauge")
                }
                .tag(0)

            CurvesTabView(observer: observer)
                .tabItem {
                    Label("Curves", systemImage: "waveform.circle")
                }
                .tag(1)

            ProfilesTabView(observer: observer)
                .tabItem {
                    Label("Profiles & Rules", systemImage: "slider.horizontal.3")
                }
                .tag(2)
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}

// MARK: - Dashboard Tab

struct DashboardTabView: View {
    @ObservedObject var observer: DaemonClientObserver

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let status = observer.status {
                    // Temperature Cards
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Temperature Sensors")
                            .font(.headline)
                            .padding(.horizontal)

                        ForEach(status.sensors, id: \.groupName) { sensor in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(sensor.groupName.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.body)
                                    Text("Mean: \(String(format: "%.1f", sensor.meanTemp))°C")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text(String(format: "%.0f°C", sensor.maxTemp))
                                        .font(.title3)
                                        .monospacedDigit()
                                }
                            }
                            .padding()
                            .background(Color(.controlBackgroundColor))
                            .cornerRadius(8)
                            .padding(.horizontal)
                        }
                    }

                    // Fan Status
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Fan Status")
                            .font(.headline)
                            .padding(.horizontal)

                        ForEach(status.fans, id: \.fanIndex) { fan in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Fan \(fan.fanIndex)")
                                        .font(.body)
                                    Text("Actual RPM")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text(String(format: "%.0f", fan.actualRPM))
                                        .font(.title3)
                                        .monospacedDigit()
                                    Text(String(format: "Target: %.0f", fan.targetRPM))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding()
                            .background(Color(.controlBackgroundColor))
                            .cornerRadius(8)
                            .padding(.horizontal)
                        }
                    }

                    // Power
                    if let watts = status.packageWatts {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Power")
                                .font(.headline)
                                .padding(.horizontal)

                            HStack {
                                Text("Package Power")
                                Spacer()
                                Text(String(format: "%.1f W", watts))
                                    .font(.title3)
                                    .monospacedDigit()
                            }
                            .padding()
                            .background(Color(.controlBackgroundColor))
                            .cornerRadius(8)
                            .padding(.horizontal)
                        }
                    }
                } else {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                        Text("Unable to Load Dashboard")
                            .font(.headline)
                        Text("Daemon is not responding.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
            }
            .padding(.vertical)
        }
    }
}

// MARK: - Curves Tab

struct CurvesTabView: View {
    @ObservedObject var observer: DaemonClientObserver

    var body: some View {
        VStack {
            if let config = observer.config {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Temperature → RPM Curves")
                            .font(.headline)
                            .padding(.horizontal)

                        let activeProfile = config.pinnedProfile ?? "balanced"
                        if let profile = config.profiles[activeProfile] {
                            ForEach(Array(profile.curves.sorted { $0.key < $1.key }), id: \.key) { fanIndex, curve in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Fan \(fanIndex) Curve")
                                        .font(.subheadline)
                                        .padding(.horizontal)

                                    Canvas { context, size in
                                        let width: CGFloat = size.width
                                        let height: CGFloat = size.height
                                        let minTemp = 30.0
                                        let maxTemp = 110.0
                                        let minRPM = 0.0
                                        let maxRPM = 7000.0

                                        var path = Path()
                                        for i in stride(from: minTemp, to: maxTemp + 1, by: 20) {
                                            let x = (i - minTemp) / (maxTemp - minTemp) * width
                                            path.move(to: CGPoint(x: x, y: 0))
                                            path.addLine(to: CGPoint(x: x, y: height))
                                        }
                                        context.stroke(path, with: .color(.gray.opacity(0.2)), lineWidth: 0.5)

                                        var curvePath = Path()
                                        for (i, point) in curve.points.enumerated() {
                                            let x = (point.temp - minTemp) / (maxTemp - minTemp) * width
                                            let y = height - (point.rpm - minRPM) / (maxRPM - minRPM) * height

                                            if i == 0 {
                                                curvePath.move(to: CGPoint(x: x, y: y))
                                            } else {
                                                curvePath.addLine(to: CGPoint(x: x, y: y))
                                            }
                                        }
                                        context.stroke(curvePath, with: .color(.blue), lineWidth: 2)

                                        for point in curve.points {
                                            let x = (point.temp - minTemp) / (maxTemp - minTemp) * width
                                            let y = height - (point.rpm - minRPM) / (maxRPM - minRPM) * height

                                            context.fill(
                                                Circle().path(in: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)),
                                                with: .color(.blue)
                                            )
                                        }
                                    }
                                    .frame(height: 200)
                                    .background(Color(.controlBackgroundColor))
                                    .cornerRadius(8)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Control Points")
                                            .font(.caption)
                                            .foregroundColor(.secondary)

                                        ForEach(curve.points, id: \.temp) { point in
                                            HStack {
                                                Text("\(String(format: "%.0f", point.temp))°C")
                                                    .monospacedDigit()
                                                Spacer()
                                                Text("\(String(format: "%.0f", point.rpm)) RPM")
                                                    .monospacedDigit()
                                            }
                                            .font(.caption)
                                        }
                                    }
                                    .padding()
                                    .background(Color(.controlBackgroundColor))
                                    .cornerRadius(8)
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                }
            } else {
                VStack {
                    Text("Loading Curves…")
                        .font(.headline)
                }
            }
        }
    }
}

// MARK: - Profiles & Rules Tab

struct ProfilesTabView: View {
    @ObservedObject var observer: DaemonClientObserver
    @State private var selectedProfile: String = "balanced"

    var body: some View {
        VStack {
            if let config = observer.config {
                HStack {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Active Profile")
                            .font(.headline)

                        Picker("Profile", selection: $selectedProfile) {
                            ForEach(Array(config.profiles.keys).sorted(), id: \.self) { name in
                                Text(name.capitalized).tag(name)
                            }
                        }
                        .onChange(of: selectedProfile) { _, newValue in
                            Task {
                                _ = await observer.setProfile(newValue)
                            }
                        }

                        Spacer()
                    }

                    Spacer()
                }
                .padding()

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Rules")
                        .font(.headline)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(config.rules.rules.sorted { $0.priority > $1.priority }, id: \.priority) { rule in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("Priority: \(rule.priority)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        Text(rule.profileName)
                                            .font(.caption)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.2))
                                            .cornerRadius(4)
                                    }

                                    Text(ruleTriggerDescription(rule.trigger))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                                .background(Color(.controlBackgroundColor))
                                .cornerRadius(6)
                            }
                        }
                    }
                }
                .padding()
            } else {
                Text("Loading Profiles…")
                    .font(.headline)
            }
        }
    }

    private func ruleTriggerDescription(_ trigger: RuleTrigger) -> String {
        switch trigger {
        case .onBattery:
            return "When on battery power"
        case .onAC:
            return "When on AC power"
        case .clamshellClosed:
            return "When clamshell closed"
        case .externalDisplayConnected:
            return "When external display connected"
        case .appRunning(let bundleId):
            return "When app running: \(bundleId)"
        case .gameDetected:
            return "When game detected"
        case .timeWindow(let start, let end):
            return "Time window: \(start):00–\(end):00"
        }
    }
}

// MARK: - TelemetrySnapshot (Serialization)

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
}
