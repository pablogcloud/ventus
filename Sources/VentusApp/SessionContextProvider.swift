import AppKit
import Combine
import Foundation
import IOKit.ps
import VentusCore
import os.log

/// Gathers the GUI-session facts that rules depend on and pushes them to the
/// daemon.
///
/// This lives in the app because it has to. `ventusd` is a root LaunchDaemon
/// running outside any GUI session, so `NSWorkspace.runningApplications`, the
/// frontmost application and fullscreen state are unreachable from it. The
/// daemon supplies GPU power and the clock — the two things it *can* see — and
/// evaluates the rules itself, so this class never decides anything. It only
/// reports.
@MainActor
final class SessionContextProvider {
    private let observer: DaemonClientObserver
    private var observers: [NSObjectProtocol] = []
    private var heartbeat: Timer?
    private var last: SessionContext?
    private var powerSourceSource: CFRunLoopSource?
    private var cancellables = Set<AnyCancellable>()

    /// Well under the daemon's 30s staleness window, so two missed pushes still
    /// leave the context trusted.
    private static let heartbeatS: TimeInterval = 10

    init(observer: DaemonClientObserver) {
        self.observer = observer
    }

    deinit {
        // Not reached in the current lifecycle (AppDelegate owns this for the
        // life of the process), but the IOPS run-loop source holds an unretained
        // pointer to self — releasing without unregistering would leave the
        // callback aimed at freed memory.
        MainActor.assumeIsolated { stop() }
    }

    func start() {
        guard observers.isEmpty, heartbeat == nil, cancellables.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            observers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.push() }
                }
            )
        }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.push() }
            }
        )

        // The daemon discards its session context on wake, because its clock
        // excludes sleep and would otherwise call three-hour-old facts fresh.
        // Report immediately so that gap is a moment, not a heartbeat.
        observers.append(
            workspace.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.push(force: true) }
            }
        )

        // The first push at start() lands before the XPC client has finished
        // connecting, so it is dropped and nothing reaches the daemon until the
        // heartbeat — leaving rules unapplied for up to 10s after launch, on top
        // of the transition dwell. Push again the moment the link comes up.
        observer.$isConnected
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.push(force: true) }
            }
            .store(in: &cancellables)

        // Power-source changes have no NotificationCenter equivalent; IOKit
        // hands back a run-loop source instead.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let provider = Unmanaged<SessionContextProvider>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { provider.push() }
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceSource = source
        }

        // Fullscreen has no notification at all — entering fullscreen in
        // another app is invisible to us — so the heartbeat doubles as the
        // polling interval for it.
        let timer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatS, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.push(force: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer

        push(force: true)
    }

    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        heartbeat?.invalidate()
        heartbeat = nil
        cancellables.removeAll()
        if let source = powerSourceSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceSource = nil
        }
    }

    // MARK: - Capture

    private func push(force: Bool = false) {
        let context = capture()
        // Notifications arrive in bursts (activating an app fires several), so
        // skip identical pushes; the heartbeat forces one regardless to keep
        // the daemon's staleness window fresh.
        guard force || context != last else { return }
        last = context
        Task { await observer.pushSessionContext(context) }
    }

    private func capture() -> SessionContext {
        let apps = NSWorkspace.shared.runningApplications
        let bundleIDs = Set(apps.compactMap(\.bundleIdentifier))
        let frontmost = NSWorkspace.shared.frontmostApplication

        let (external, builtIn) = Self.displays()

        return SessionContext(
            onBattery: Self.isOnBattery(),
            // No public API reports the lid directly. The reliable proxy: the
            // built-in panel disappears from NSScreen when the lid shuts while
            // an external display keeps the Mac awake.
            clamshellClosed: !builtIn && external,
            externalDisplayConnected: external,
            runningBundleIDs: bundleIDs,
            frontmostBundleID: frontmost?.bundleIdentifier,
            frontmostIsFullscreen: Self.isFullscreen(pid: frontmost?.processIdentifier)
        )
    }

    private static func isOnBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                let state = desc[kIOPSPowerSourceStateKey] as? String
            else { continue }
            if state == kIOPSBatteryPowerValue { return true }
        }
        return false
    }

    /// (anExternalDisplayIsPresent, theBuiltInPanelIsPresent)
    private static func displays() -> (external: Bool, builtIn: Bool) {
        var external = false, builtIn = false
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else { continue }
            if CGDisplayIsBuiltin(number) != 0 { builtIn = true } else { external = true }
        }
        return (external, builtIn)
    }

    /// Fullscreen by geometry: the frontmost app owns an on-screen window that
    /// covers a whole display.
    ///
    /// `CGWindowListCopyWindowInfo` returns bounds and owner PID without the
    /// Screen Recording permission — only window *titles* and captured *images*
    /// are gated — so this adds no permission prompt.
    private static func isFullscreen(pid: pid_t?) -> Bool {
        guard let pid else { return false }
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let screenFrames = NSScreen.screens.map(\.frame)

        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            for frame in screenFrames
            where abs(bounds.width - frame.width) < 2 && abs(bounds.height - frame.height) < 2 {
                return true
            }
        }
        return false
    }
}
