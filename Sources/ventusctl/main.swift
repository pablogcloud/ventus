import Foundation
import VentusCore

// MARK: - Exit Codes

let EXIT_SUCCESS = 0
let EXIT_USAGE_ERROR = 2
let EXIT_DAEMON_UNREACHABLE = 3
let EXIT_DAEMON_ERROR = 4

// MARK: - XPC Proxy Protocol

@objc protocol VentusXPCProtocol {
    func getStatus(reply: @escaping (Data) -> Void)
    func getConfig(reply: @escaping (Data) -> Void)
    func setConfig(_ configData: Data, reply: @escaping (Data) -> Void)
    func setProfile(_ profileName: String, reply: @escaping (Data) -> Void)
    func arm(reply: @escaping (Data) -> Void)
    func disarm(reply: @escaping (Data) -> Void)
    func setAppleAuto(reply: @escaping (Data) -> Void)
}

// MARK: - Data Structures

struct XPCResult: Codable {
    let success: Bool
    let error: String?
    let data: String?
}

struct TelemetrySnapshot: Codable {
    struct FanInfo: Codable {
        let fanIndex: Int
        let actualRPM: Double
        let targetRPM: Double
    }

    struct SensorInfo: Codable {
        let groupName: String
        let maxTemp: Double
        let meanTemp: Double
        let count: Int
    }

    struct Explanation: Codable {
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

// MARK: - XPC Client

class XPCClient {
    private let connection: NSXPCConnection

    init?() {
        let connection = NSXPCConnection(machServiceName: "com.formm.ventus.daemon", options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: VentusXPCProtocol.self)
        self.connection = connection
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    enum XPCError: Error {
        case timeout
        case daemonNotRunning
        case decodingFailed(Error)
        case other(String)
    }

    func callXPC<T: Decodable>(
        method: String,
        arguments: Any? = nil,
        responseType: T.Type
    ) -> Result<T, XPCError> {
        var result: Result<T, XPCError>?
        let semaphore = DispatchSemaphore(value: 0)

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            let nsError = error as NSError
            if nsError.code == NSXPCConnectionInterrupted || nsError.code == NSXPCConnectionInvalid {
                result = .failure(.daemonNotRunning)
            } else {
                result = .failure(.other(error.localizedDescription))
            }
            semaphore.signal()
        } as! VentusXPCProtocol

        switch method {
        case "getStatus":
            proxy.getStatus { data in
                do {
                    let decoded = try JSONDecoder().decode(T.self, from: data)
                    result = .success(decoded)
                } catch {
                    result = .failure(.decodingFailed(error))
                }
                semaphore.signal()
            }
        case "getConfig":
            proxy.getConfig { data in
                do {
                    let decoded = try JSONDecoder().decode(T.self, from: data)
                    result = .success(decoded)
                } catch {
                    result = .failure(.decodingFailed(error))
                }
                semaphore.signal()
            }
        case "setConfig":
            if let configData = arguments as? Data {
                proxy.setConfig(configData) { data in
                    do {
                        let decoded = try JSONDecoder().decode(T.self, from: data)
                        result = .success(decoded)
                    } catch {
                        result = .failure(.decodingFailed(error))
                    }
                    semaphore.signal()
                }
            }
        case "setProfile":
            if let profileName = arguments as? String {
                proxy.setProfile(profileName) { data in
                    do {
                        let decoded = try JSONDecoder().decode(T.self, from: data)
                        result = .success(decoded)
                    } catch {
                        result = .failure(.decodingFailed(error))
                    }
                    semaphore.signal()
                }
            }
        case "arm":
            proxy.arm { data in
                do {
                    let decoded = try JSONDecoder().decode(T.self, from: data)
                    result = .success(decoded)
                } catch {
                    result = .failure(.decodingFailed(error))
                }
                semaphore.signal()
            }
        case "disarm":
            proxy.disarm { data in
                do {
                    let decoded = try JSONDecoder().decode(T.self, from: data)
                    result = .success(decoded)
                } catch {
                    result = .failure(.decodingFailed(error))
                }
                semaphore.signal()
            }
        case "setAppleAuto":
            proxy.setAppleAuto { data in
                do {
                    let decoded = try JSONDecoder().decode(T.self, from: data)
                    result = .success(decoded)
                } catch {
                    result = .failure(.decodingFailed(error))
                }
                semaphore.signal()
            }
        default:
            result = .failure(.other("Unknown method: \(method)"))
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + 5.5)
        if waitResult == .timedOut {
            return .failure(.timeout)
        }

        return result ?? .failure(.timeout)
    }
}

// MARK: - Command Handlers

func printUsage() {
    let usage = """
    ventusctl - Ventus fan control CLI

    Usage:
      ventusctl status [--json]         Print current fan status
      ventusctl watch [-i SECONDS]      Watch status updates (default 2s)
      ventusctl profile NAME [--pin]    Set active profile
      ventusctl arm                     Enable hardware control (WARNING)
      ventusctl disarm                  Disable hardware control
      ventusctl set-auto                Release to macOS auto mode
      ventusctl config get              Print configuration JSON
      ventusctl config set FILE.json    Load configuration from file
      ventusctl help                    Print this message

    Exit codes:
      0 = success
      2 = usage error
      3 = daemon unreachable
      4 = daemon error
    """
    print(usage)
}

func formatUptime(_ seconds: TimeInterval) -> String {
    let hours = Int(seconds) / 3600
    let minutes = (Int(seconds) % 3600) / 60
    let secs = Int(seconds) % 60
    return String(format: "%dh %dm %ds", hours, minutes, secs)
}

func commandStatus(args: [String]) -> Int32 {
    guard let client = XPCClient() else {
        fputs("daemon not running — install with sudo scripts/install.sh\n", stderr)
        return Int32(EXIT_DAEMON_UNREACHABLE)
    }

    let jsonOutput = args.contains("--json")

    switch client.callXPC(method: "getStatus", responseType: TelemetrySnapshot.self) {
    case .success(let snapshot):
        if jsonOutput {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let jsonData = try encoder.encode(snapshot)
                if let jsonString = String(data: jsonData, encoding: .utf8) {
                    print(jsonString)
                }
            } catch {
                fputs("Failed to encode JSON: \(error)\n", stderr)
                return Int32(EXIT_DAEMON_ERROR)
            }
        } else {
            // Human-readable format
            print("Ventus Status (v\(snapshot.version))")
            print("Mode: \(snapshot.mode)")
            print("Active profile: \(snapshot.activeProfile)\(snapshot.activeRule.map { " (rule: \($0))" } ?? "")")
            print("Uptime: \(formatUptime(snapshot.uptime))")
            print("")

            if !snapshot.sensors.isEmpty {
                print("Temperature sensors:")
                for sensor in snapshot.sensors.sorted(by: { $0.groupName < $1.groupName }) {
                    print("  \(sensor.groupName): max=\(String(format: "%.1f", sensor.maxTemp))°C mean=\(String(format: "%.1f", sensor.meanTemp))°C (\(sensor.count) sensors)")
                }
            } else {
                print("Temperature sensors: (none)")
            }
            print("")

            if !snapshot.fans.isEmpty {
                print("Fan status:")
                for fan in snapshot.fans.sorted(by: { $0.fanIndex < $1.fanIndex }) {
                    print("  Fan \(fan.fanIndex): \(Int(fan.actualRPM)) RPM (target: \(Int(fan.targetRPM)) RPM)")
                }
            } else {
                print("Fan status: (none)")
            }
            print("")

            if let watts = snapshot.packageWatts {
                print("Package power: \(String(format: "%.1f", watts)) W")
            } else {
                print("Package power: N/A")
            }
        }
        return Int32(EXIT_SUCCESS)

    case .failure(let error):
        switch error {
        case .daemonNotRunning:
            fputs("daemon not running — install with sudo scripts/install.sh\n", stderr)
            return Int32(EXIT_DAEMON_UNREACHABLE)
        case .timeout:
            fputs("daemon not running — install with sudo scripts/install.sh\n", stderr)
            return Int32(EXIT_DAEMON_UNREACHABLE)
        default:
            fputs("Error: \(error)\n", stderr)
            return Int32(EXIT_DAEMON_ERROR)
        }
    }
}

func commandWatch(args: [String]) -> Int32 {
    guard let client = XPCClient() else {
        fputs("daemon not running — install with sudo scripts/install.sh\n", stderr)
        return Int32(EXIT_DAEMON_UNREACHABLE)
    }

    var interval: TimeInterval = 2.0
    var i = 0
    while i < args.count {
        if args[i] == "-i" && i + 1 < args.count {
            if let value = Double(args[i + 1]) {
                interval = value
            }
            i += 2
        } else {
            i += 1
        }
    }

    print("Press Ctrl-C to stop\n")

    let startTime = Date()
    while true {
        switch client.callXPC(method: "getStatus", responseType: TelemetrySnapshot.self) {
        case .success(let snapshot):
            let elapsed = Date().timeIntervalSince(startTime)
            let fanLine = snapshot.fans.isEmpty
                ? "(no fans)"
                : snapshot.fans.map { "F\($0.fanIndex):\(Int($0.actualRPM))/\(Int($0.targetRPM))" }.joined(separator: " ")
            let tempLine = snapshot.sensors.isEmpty
                ? "(no sensors)"
                : snapshot.sensors.map { "\($0.groupName):\(String(format: "%.0f", $0.maxTemp))°" }.joined(separator: " ")
            let wattLine = snapshot.packageWatts.map { String(format: "%.0fW", $0) } ?? "N/A"

            print("[\(String(format: "%.0f", elapsed))s] \(snapshot.mode) | Profile: \(snapshot.activeProfile) | Sensors: \(tempLine) | Fans: \(fanLine) | Power: \(wattLine)")
            fflush(stdout)

            Thread.sleep(forTimeInterval: interval)

        case .failure(let error):
            switch error {
            case .daemonNotRunning, .timeout:
                fputs("daemon not running — install with sudo scripts/install.sh\n", stderr)
                return Int32(EXIT_DAEMON_UNREACHABLE)
            default:
                fputs("Error: \(error)\n", stderr)
                return Int32(EXIT_DAEMON_ERROR)
            }
        }
    }
}

func commandProfile(args: [String]) -> Int32 {
    guard args.count >= 1 else {
        fputs("Usage: ventusctl profile <name> [--pin]\n", stderr)
        return Int32(EXIT_USAGE_ERROR)
    }

    let profileName = args[0]

    guard let client = XPCClient() else {
        fputs("daemon not running — install with sudo scripts/install.sh\n", stderr)
        return Int32(EXIT_DAEMON_UNREACHABLE)
    }

    switch client.callXPC(method: "setProfile", arguments: profileName, responseType: XPCResult.self) {
    case .success(let result):
        if result.success {
            print("Profile '\(profileName)' set")
            return Int32(EXIT_SUCCESS)
        } else {
            fputs("Error: \(result.error ?? "Unknown error")\n", stderr)
            return Int32(EXIT_DAEMON_ERROR)
        }
    case .failure(let error):
        switch error {
        case .daemonNotRunning, .timeout:
            fputs("daemon not running — install with sudo scripts/install.sh\n", stderr)
            return Int32(EXIT_DAEMON_UNREACHABLE)
        default:
            fputs("Error: \(error)\n", stderr)
            return Int32(EXIT_DAEMON_ERROR)
        }
    }
}

func commandArm() -> Int32 {
    guard let client = XPCClient() else {
        fputs("daemon not running — install with sudo scripts/install.sh\n", stderr)
        return Int32(EXIT_DAEMON_UNREACHABLE)
    }

    print("WARNING: Enabling hardware fan control writes.")
    print("The daemon will now directly control your fans.")
    print("Incorrect curves can cause thermal damage.")
    print("")

    switch client.callXPC(method: "arm", responseType: XPCResult.self) {
    case .success(let result):
        if result.success {
            print("Armed. Hardware control enabled.")
            return Int32(EXIT_SUCCESS)
        } else {
            fputs("Error: \(result.error ?? "Unknown error")\n", stderr)
            return Int32(EXIT_DAEMON_ERROR)
        }
    case .failure(let error):
        switch error {
        case .daemonNotRunning, .timeout:
            fputs("daemon not running — install with sudo scripts/install.sh\n", stderr)
            return Int32(EXIT_DAEMON_UNREACHABLE)
        default:
            fputs("Error: \(error)\n", stderr)
            return Int32(EXIT_DAEMON_ERROR)
        }
    }
}

func commandDisarm() -> Int32 {
    guard let client = XPCClient() else {
        fputs("daemon not running — install with sudo scripts/install.sh\n", stderr)
        return Int32(EXIT_DAEMON_UNREACHABLE)
    }

    switch client.callXPC(method: "disarm", responseType: XPCResult.self) {
    case .success(let result):
        if result.success {
            print("Disarmed. Hardware control disabled.")
            return Int32(EXIT_SUCCESS)
        } else {
            fputs("Error: \(result.error ?? "Unknown error")\n", stderr)
            return Int32(EXIT_DAEMON_ERROR)
        }
    case .failure(let error):
        switch error {
        case .daemonNotRunning, .timeout:
            fputs("daemon not running — install with sudo scripts/install.sh\n", stderr)
            return Int32(EXIT_DAEMON_UNREACHABLE)
        default:
            fputs("Error: \(error)\n", stderr)
            return Int32(EXIT_DAEMON_ERROR)
        }
    }
}

func commandSetAuto() -> Int32 {
    guard let client = XPCClient() else {
        fputs("daemon not running — install with sudo scripts/install.sh\n", stderr)
        return Int32(EXIT_DAEMON_UNREACHABLE)
    }

    switch client.callXPC(method: "setAppleAuto", responseType: XPCResult.self) {
    case .success(let result):
        if result.success {
            print("Fans released to macOS auto mode.")
            return Int32(EXIT_SUCCESS)
        } else {
            fputs("Error: \(result.error ?? "Unknown error")\n", stderr)
            return Int32(EXIT_DAEMON_ERROR)
        }
    case .failure(let error):
        switch error {
        case .daemonNotRunning, .timeout:
            fputs("daemon not running — install with sudo scripts/install.sh\n", stderr)
            return Int32(EXIT_DAEMON_UNREACHABLE)
        default:
            fputs("Error: \(error)\n", stderr)
            return Int32(EXIT_DAEMON_ERROR)
        }
    }
}

func commandConfigGet() -> Int32 {
    guard let client = XPCClient() else {
        fputs("daemon not running — install with sudo scripts/install.sh\n", stderr)
        return Int32(EXIT_DAEMON_UNREACHABLE)
    }

    switch client.callXPC(method: "getConfig", responseType: Data.self) {
    case .success(let data):
        if let jsonString = String(data: data, encoding: .utf8) {
            print(jsonString)
        }
        return Int32(EXIT_SUCCESS)
    case .failure(let error):
        switch error {
        case .daemonNotRunning, .timeout:
            fputs("daemon not running — install with sudo scripts/install.sh\n", stderr)
            return Int32(EXIT_DAEMON_UNREACHABLE)
        default:
            fputs("Error: \(error)\n", stderr)
            return Int32(EXIT_DAEMON_ERROR)
        }
    }
}

func commandConfigSet(filePath: String) -> Int32 {
    guard let client = XPCClient() else {
        fputs("daemon not running — install with sudo scripts/install.sh\n", stderr)
        return Int32(EXIT_DAEMON_UNREACHABLE)
    }

    do {
        let configData = try Data(contentsOf: URL(fileURLWithPath: filePath))

        switch client.callXPC(method: "setConfig", arguments: configData, responseType: XPCResult.self) {
        case .success(let result):
            if result.success {
                print("Configuration updated successfully.")
                return Int32(EXIT_SUCCESS)
            } else {
                fputs("Configuration error: \(result.error ?? "Unknown error")\n", stderr)
                return Int32(EXIT_DAEMON_ERROR)
            }
        case .failure(let error):
            switch error {
            case .daemonNotRunning, .timeout:
                fputs("daemon not running — install with sudo scripts/install.sh\n", stderr)
                return Int32(EXIT_DAEMON_UNREACHABLE)
            default:
                fputs("Error: \(error)\n", stderr)
                return Int32(EXIT_DAEMON_ERROR)
            }
        }
    } catch {
        fputs("Failed to read config file: \(error)\n", stderr)
        return Int32(EXIT_USAGE_ERROR)
    }
}

// MARK: - Main

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : ""
let args = arguments.count > 2 ? Array(arguments.dropFirst(2)) : []

let exitCode: Int32
switch command {
case "status":
    exitCode = Int32(commandStatus(args: args))
case "watch":
    exitCode = Int32(commandWatch(args: args))
case "profile":
    exitCode = Int32(commandProfile(args: args))
case "arm":
    exitCode = Int32(commandArm())
case "disarm":
    exitCode = Int32(commandDisarm())
case "set-auto":
    exitCode = Int32(commandSetAuto())
case "config":
    if args.count > 0 {
        let subcommand = args[0]
        let subargs = Array(args.dropFirst())
        if subcommand == "get" {
            exitCode = Int32(commandConfigGet())
        } else if subcommand == "set" {
            if subargs.count > 0 {
                exitCode = Int32(commandConfigSet(filePath: subargs[0]))
            } else {
                fputs("Usage: ventusctl config set <file.json>\n", stderr)
                exitCode = Int32(EXIT_USAGE_ERROR)
            }
        } else {
            fputs("Usage: ventusctl config [get|set]\n", stderr)
            exitCode = Int32(EXIT_USAGE_ERROR)
        }
    } else {
        fputs("Usage: ventusctl config [get|set]\n", stderr)
        exitCode = Int32(EXIT_USAGE_ERROR)
    }
case "help", "":
    printUsage()
    exitCode = Int32(command == "help" ? EXIT_SUCCESS : EXIT_USAGE_ERROR)
default:
    fputs("Unknown command: \(command)\n", stderr)
    printUsage()
    exitCode = Int32(EXIT_USAGE_ERROR)
}

exit(exitCode)
