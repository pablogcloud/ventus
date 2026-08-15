import Foundation

/// XPC protocol for communication between daemon and clients.
/// This protocol defines all methods available via NSXPCConnection.
@objc public protocol VentusXPCProtocol {
    /// Returns current daemon telemetry as JSON Data.
    /// reply: (Data) -> Void receives a JSON-encoded TelemetrySnapshot
    func getStatus(reply: @escaping (Data) -> Void)

    /// Returns current daemon configuration as JSON Data.
    func getConfig(reply: @escaping (Data) -> Void)

    /// Sets daemon configuration from JSON Data.
    /// reply: (Data) -> Void receives validation result (error message or empty if ok)
    func setConfig(_ configData: Data, reply: @escaping (Data) -> Void)

    /// Sets the active profile by name. This is a MANUAL pin: it suspends rule
    /// evaluation until `setAutoProfile` releases it.
    func setProfile(_ profileName: String, reply: @escaping (Data) -> Void)

    /// Clears the manual pin, handing profile selection back to the rules.
    ///
    /// A dedicated method rather than a whole-config write: `setConfig` is
    /// read-modify-write with no revision token, and clients never re-fetch
    /// config after connecting, so using it here would risk clobbering
    /// concurrent changes with a stale copy.
    func setAutoProfile(reply: @escaping (Data) -> Void)

    /// Pushes facts about the GUI session that the daemon cannot observe
    /// itself — running apps, frontmost app, fullscreen, displays, power
    /// source. JSON-encoded `SessionContext`. The daemon timestamps each one
    /// and stops trusting session-dependent triggers once it goes stale.
    func setSessionContext(_ contextData: Data, reply: @escaping (Data) -> Void)

    /// Enables armed mode (hardware writes allowed).
    func arm(reply: @escaping (Data) -> Void)

    /// Disables armed mode (hardware writes blocked).
    func disarm(reply: @escaping (Data) -> Void)

    /// Forces fans to Apple auto mode (FxMd=0).
    func setAppleAuto(reply: @escaping (Data) -> Void)
}

/// Codable result for XPC replies.
public struct XPCResult: Codable, Sendable {
    public let success: Bool
    public let error: String?
    public let data: String?

    public static func ok(data: String? = nil) -> XPCResult {
        XPCResult(success: true, error: nil, data: data)
    }

    public static func error(_ message: String) -> XPCResult {
        XPCResult(success: false, error: message, data: nil)
    }
}
