import Foundation

/// Facts about the logged-in GUI session that rules depend on.
///
/// This type exists because `ventusd` is a root LaunchDaemon: it runs outside
/// any GUI session, so `NSWorkspace.runningApplications`, the frontmost app and
/// fullscreen state are simply unreachable from it. VentusApp gathers them and
/// pushes them over XPC; the daemon merges in GPU power and the clock, which it
/// already has, and evaluates. The daemon gains an input, not a privilege.
public struct SessionContext: Codable, Equatable, Sendable {
    public var onBattery: Bool
    public var clamshellClosed: Bool
    public var externalDisplayConnected: Bool
    public var runningBundleIDs: Set<String>
    public var frontmostBundleID: String?
    public var frontmostIsFullscreen: Bool

    public init(
        onBattery: Bool = false,
        clamshellClosed: Bool = false,
        externalDisplayConnected: Bool = false,
        runningBundleIDs: Set<String> = [],
        frontmostBundleID: String? = nil,
        frontmostIsFullscreen: Bool = false
    ) {
        self.onBattery = onBattery
        self.clamshellClosed = clamshellClosed
        self.externalDisplayConnected = externalDisplayConnected
        self.runningBundleIDs = runningBundleIDs
        self.frontmostBundleID = frontmostBundleID
        self.frontmostIsFullscreen = frontmostIsFullscreen
    }
}
