import Foundation

/// XPC protocol for communication between daemon and clients.
/// This protocol defines all methods available via NSXPCConnection.
@objc protocol VentusXPCProtocol {
    /// Returns current daemon telemetry as JSON Data.
    /// reply: (Data) -> Void receives a JSON-encoded TelemetrySnapshot
    func getStatus(reply: @escaping (Data) -> Void)

    /// Returns current daemon configuration as JSON Data.
    func getConfig(reply: @escaping (Data) -> Void)

    /// Sets daemon configuration from JSON Data.
    /// reply: (Data) -> Void receives validation result (error message or empty if ok)
    func setConfig(_ configData: Data, reply: @escaping (Data) -> Void)

    /// Sets the active profile by name.
    func setProfile(_ profileName: String, reply: @escaping (Data) -> Void)

    /// Enables armed mode (hardware writes allowed).
    func arm(reply: @escaping (Data) -> Void)

    /// Disables armed mode (hardware writes blocked).
    func disarm(reply: @escaping (Data) -> Void)

    /// Forces fans to Apple auto mode (FxMd=0).
    func setAppleAuto(reply: @escaping (Data) -> Void)
}

/// Codable result for XPC replies.
struct XPCResult: Codable, Sendable {
    let success: Bool
    let error: String?
    let data: String?

    static func ok(data: String? = nil) -> XPCResult {
        XPCResult(success: true, error: nil, data: data)
    }

    static func error(_ message: String) -> XPCResult {
        XPCResult(success: false, error: message, data: nil)
    }
}
