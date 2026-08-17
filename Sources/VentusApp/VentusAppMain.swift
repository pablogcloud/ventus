import SwiftUI
import AppKit
import Combine
#if DEBUG
import SceneKit
#endif

@main
struct VentusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        VentusTheme.registerFonts()
    }

    var body: some Scene {
        // The menu-bar item + panel are hosted by AppDelegate via AppKit.
        // SwiftUI's MenuBarExtra(.window) does NOT reliably re-render its
        // content on state changes, and NSPopover on macOS 26 wraps content in
        // a Liquid Glass frame (NSGlassView + 13pt margins + arrow) that can't
        // be tinted to match the Ventus surface. A borderless anchored NSPanel
        // gives the clean rounded card from the approved mockup.
        // (SceneBuilder can't gate defaultLaunchBehavior(.suppressed) behind
        // #available on the macOS 14 target; AppDelegate closes the
        // auto-presented launch window instead.)
        Window("Ventus", id: "mainWindow") {
            MainWindowView(observer: appDelegate.daemonClient)
        }
        .windowStyle(.hiddenTitleBar)
        .keyboardShortcut("1", modifiers: .command)
    }
}

/// Borderless windows refuse key status by default; the panel's controls need
/// it to take the first click without activating the app.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let daemonClient = DaemonClientObserver()
    private lazy var sessionContext = SessionContextProvider(observer: daemonClient)
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    // Menu-bar app: closing the main window (including the close-at-launch
    // below) must never quit the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Documentation renderer: draw the shipped views offscreen and exit.
        // No status item, no daemon connection, nothing on screen.
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--render-shots"), args.count > flag + 1 {
            NSApp.setActivationPolicy(.prohibited)
            ShotRenderer.render(into: args[flag + 1])
            exit(0)
        }

        NSApp.setActivationPolicy(.accessory)   // menu-bar-only, no dock icon

        // Menu-bar app: close the main window SwiftUI auto-presents at launch.
        DispatchQueue.main.async {
            NSApp.windows
                .filter { $0.identifier?.rawValue == "mainWindow" }
                .forEach { $0.close() }
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "fan",
                accessibilityDescription: "Ventus"
            )
            button.imagePosition = .imageLeading
            button.title = " --°"
            button.target = self
            button.action = #selector(togglePanel(_:))
        }
        self.statusItem = item

        // Rules need GUI-session facts the root daemon cannot observe; this
        // starts reporting them. Everything else about rules happens daemon-side.
        sessionContext.start()

        #if DEBUG
        // Debug hook (DEBUG builds only — compiled out of release entirely):
        // lets local tooling drive UI surfaces when accessibility clicking is
        // unavailable. Requires ~/.ventus-debug to contain a non-empty secret
        // token, every command must carry it ("<token>:<command>"), and the
        // file is re-checked per event so deleting it takes effect immediately.
        let debugTokenPath = NSString(string: "~/.ventus-debug").expandingTildeInPath
        if let launchToken = try? String(contentsOfFile: debugTokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !launchToken.isEmpty {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.formm.ventus.debug.command"),
                object: nil,
                queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self,
                          let payload = note.object as? String,
                          payload.hasPrefix(launchToken + ":"),
                          let currentToken = try? String(
                              contentsOfFile: debugTokenPath, encoding: .utf8
                          ).trimmingCharacters(in: .whitespacesAndNewlines),
                          currentToken == launchToken
                    else { return }
                    let command = String(payload.dropFirst(launchToken.count + 1))
                    switch Optional(command) {
                    case "showPopover":
                        self.showPanel()
                    case "hidePopover":
                        self.closePanel()
                    case "frames":
                        self.dumpDebugFrames()
                    case "rendercup":
                        self.renderCupSamples()
                    case "pin":
                        self.debugPinned = true
                    case "unpin":
                        self.debugPinned = false
                    case let s? where s.hasPrefix("click:"):
                        if let panel = self.panel, panel.isVisible {
                            self.synthesizeClick(in: panel, topLeft: Self.parsePoint(s))
                        }
                    case let s? where s.hasPrefix("clickmain:"):
                        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "mainWindow" }) {
                            self.synthesizeClick(in: main, topLeft: Self.parsePoint(s))
                        }
                    case let s? where s.hasPrefix("dragmain:"):
                        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "mainWindow" }) {
                            let nums = s.split(separator: ":").last?
                                .split(separator: ",").compactMap { Double($0) } ?? []
                            if nums.count == 4 {
                                self.synthesizeDrag(
                                    in: main,
                                    from: NSPoint(x: nums[0], y: nums[1]),
                                    to: NSPoint(x: nums[2], y: nums[3])
                                )
                            }
                        }
                    case let s? where s.hasPrefix("scrollmain:"):
                        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "mainWindow" }) {
                            let nums = s.split(separator: ":").last?
                                .split(separator: ",").compactMap { Double($0) } ?? []
                            if nums.count == 3 {
                                self.synthesizeScroll(
                                    in: main,
                                    topLeft: NSPoint(x: nums[0], y: nums[1]),
                                    deltaY: nums[2]
                                )
                            }
                        }
                    default:
                        break
                    }
                }
            }
        }
        #endif

        // Close the panel whenever another window (e.g. the main window) takes
        // key — clicks inside our own windows don't hit the global monitor.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow else { return }
                if window !== self.panel, self.panel?.isVisible == true {
                    self.closePanel()
                }
            }
        }

        // Keep the menu-bar readout in sync: CPU and GPU mean temperature as a
        // stacked two-line template image — half the width of inline text.
        daemonClient.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                let cpu = status?.sensors.first { $0.groupName == "cpu_perf" }?.meanTemp
                let gpu = status?.sensors.first { $0.groupName == "gpu" }?.meanTemp
                guard let button = self?.statusItem?.button else { return }
                button.image = Self.stackedTempImage(cpu: cpu, gpu: gpu)
                button.imagePosition = .imageOnly
                button.title = ""
                let cpuText = cpu.map { String(format: "%.0f", $0) } ?? "--"
                let gpuText = gpu.map { String(format: "%.0f", $0) } ?? "--"
                button.toolTip = "Ventus — CPU \(cpuText)°C · GPU \(gpuText)°C (mean)"
            }
            .store(in: &cancellables)
    }

    /// Two stacked 9pt lines ("C58" over "G59") as a template image so the
    /// status item stays ~20pt wide and adapts to the menu-bar appearance.
    private static func stackedTempImage(cpu: Double?, gpu: Double?) -> NSImage {
        let cpuText = cpu.map { String(format: "C%.0f", $0) } ?? "C--"
        let gpuText = gpu.map { String(format: "G%.0f", $0) } ?? "G--"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let cpuSize = (cpuText as NSString).size(withAttributes: attributes)
        let gpuSize = (gpuText as NSString).size(withAttributes: attributes)
        let width = ceil(max(cpuSize.width, gpuSize.width)) + 2
        let height: CGFloat = 22
        let image = NSImage(
            size: NSSize(width: width, height: height),
            flipped: false
        ) { _ in
            (cpuText as NSString).draw(
                at: NSPoint(x: 1, y: height - cpuSize.height - 1),
                withAttributes: attributes
            )
            (gpuText as NSString).draw(
                at: NSPoint(x: 1, y: 1),
                withAttributes: attributes
            )
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        #if DEBUG
        // An explicit user toggle always wins: clear any debug pin so the
        // panel can never be left stuck open on the user's screen.
        debugPinned = false
        #endif
        if panel?.isVisible == true {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        positionPanel(panel)
        // No NSApp.activate: the panel is .nonactivatingPanel by design — it
        // must not steal focus from the frontmost app. KeyablePanel overrides
        // canBecomeKey so its controls still take the first click.
        panel.makeKeyAndOrderFront(nil)

        // Transient behavior: any click outside the panel closes it.
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor in self?.closePanel() }
            }
        }
    }

    private func closePanel() {
        #if DEBUG
        if debugPinned { return }
        #endif
        panel?.orderOut(nil)
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    /// Hosting view that responds to the FIRST click even while another app is
    /// active. Without acceptsFirstMouse, macOS swallows the initial click on
    /// the nonactivating panel as an activation click — the user presses a
    /// profile segment and nothing happens, which reads as a broken button.
    private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private func makePanel() -> NSPanel {
        let host = FirstMouseHostingView(
            rootView: PopoverView(
                observer: daemonClient,
                showMainWindow: .constant(false)
            )
        )
        host.sizingOptions = [.preferredContentSize]

        let panel = KeyablePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = host
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The card casts its own shadow in SwiftUI — see PopoverView. AppKit's
        // window shadow is cached from the backing alpha and rendered a squared
        // outline past the rounded corners.
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        host.layoutSubtreeIfNeeded()
        panel.setContentSize(host.fittingSize)

        // Borderless windows grow UPWARD from their bottom-left origin. When
        // the SwiftUI content changes height (authorization card, warnings),
        // re-anchor so the top edge stays put under the menu bar.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible,
                      let topY = self.panelTopY else { return }
                var frame = panel.frame
                if abs(frame.maxY - topY) > 0.5 {
                    frame.origin.y = topY - frame.height
                    panel.setFrame(frame, display: true)
                }
            }
        }
        self.panel = panel
        return panel
    }

    /// Screen-space Y of the panel's top edge, fixed while the panel is shown.
    private var panelTopY: CGFloat?

    #if DEBUG
    /// Debug-only: while true, the panel ignores its transient auto-close
    /// triggers so UI testing doesn't race the user's foreground activity.
    private var debugPinned = false
    #endif

    // MARK: - Debug-hook click synthesis (DEBUG builds only)

    #if DEBUG
    private static func parsePoint(_ command: String) -> NSPoint {
        let nums = command.split(separator: ":").last?
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? []
        return nums.count == 2 ? NSPoint(x: nums[0], y: nums[1]) : .zero
    }

    /// Sends a real leftMouseDown/Up pair through the window's event path —
    /// same AppKit→SwiftUI routing as a user click, no accessibility needed.
    /// Point is in the window's TOP-LEFT-origin coordinate space (like the
    /// screenshots used to derive it).
    private func synthesizeClick(in window: NSWindow, topLeft p: NSPoint) {
        let location = NSPoint(x: p.x, y: window.frame.height - p.y)
        window.makeKey()
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) {
                window.sendEvent(event)
            }
        }
    }

    /// leftMouseDown at `from`, interpolated leftMouseDragged steps, leftMouseUp
    /// at `to` — spaced over the run loop so gesture recognizers see a real drag.
    private func synthesizeDrag(in window: NSWindow, from: NSPoint, to: NSPoint) {
        func flipped(_ p: NSPoint) -> NSPoint {
            NSPoint(x: p.x, y: window.frame.height - p.y)
        }
        func mouseEvent(_ type: NSEvent.EventType, _ location: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }
        window.makeKey()
        if let down = mouseEvent(.leftMouseDown, flipped(from)) {
            window.sendEvent(down)
        }
        let steps = 12
        for step in 1 ... steps {
            let fraction = Double(step) / Double(steps)
            let p = NSPoint(
                x: from.x + (to.x - from.x) * fraction,
                y: from.y + (to.y - from.y) * fraction
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(step)) { [weak self] in
                guard self != nil else { return }
                if let drag = mouseEvent(.leftMouseDragged, flipped(p)) {
                    window.sendEvent(drag)
                }
                if step == steps, let up = mouseEvent(.leftMouseUp, flipped(to)) {
                    window.sendEvent(up)
                }
            }
        }
    }

    private func synthesizeScroll(in window: NSWindow, topLeft p: NSPoint, deltaY: Double) {
        let location = NSPoint(x: p.x, y: window.frame.height - p.y)
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(deltaY),
            wheel2: 0,
            wheel3: 0
        ) else { return }
        cgEvent.location = CGPoint(
            x: window.frame.origin.x + location.x,
            y: (NSScreen.screens.first?.frame.height ?? 0) - (window.frame.origin.y + location.y)
        )
        if let event = NSEvent(cgEvent: cgEvent) {
            window.sendEvent(event)
        }
    }

    /// Renders the 3D tip cup offscreen at each tier and writes PNGs to /tmp.
    /// A sheet cannot be captured by window id, so this verifies the actual
    /// SceneKit output — geometry, morph blend, materials, lighting — with no
    /// window and without disturbing whatever the user is doing.
    private func renderCupSamples() {
        // The last entry poses a mid-drag slosh so the surface deformation is
        // verifiable; the rest are the tiers at rest.
        let poses: [(name: String, amount: Double, tilt: CGFloat, ripple: CGFloat)] = [
            ("5", 5, 0, 0), ("10", 10, 0, 0), ("20", 20, 0, 0), ("35", 35, 0, 0),
            ("slosh", 35, Slosh.maxTilt, Slosh.maxRipple),
        ]
        for pose in poses {
            let view = SCNView(frame: NSRect(x: 0, y: 0, width: 460, height: 460))
            let coordinator = CupScene3D.Coordinator()
            view.scene = coordinator.buildScene()
            view.backgroundColor = NSColor(calibratedWhite: 0.94, alpha: 1)
            view.antialiasingMode = .multisampling4X
            coordinator.attach(to: view)
            coordinator.apply(amount: pose.amount, reduceMotion: true)
            coordinator.debugPose(
                amount: pose.amount, tiltX: pose.tilt, ripple: pose.ripple, phase: 1.1
            )
            let image = view.snapshot()
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else { continue }
            // /tmp is world-writable, so a pre-planted symlink at this
            // predictable name would redirect the write. Drop whatever is
            // there and refuse to follow anything that reappears.
            let out = URL(fileURLWithPath: "/tmp/ventus-cup-\(pose.name).png")
            try? FileManager.default.removeItem(at: out)
            try? png.write(to: out, options: [.withoutOverwriting])
        }
        logMessageApp("[Debug] rendered cup samples to /tmp/ventus-cup-*.png")
    }

    private func logMessageApp(_ s: String) { appLog.log("\(s, privacy: .public)") }

    private func dumpDebugFrames() {
        var lines: [String] = []
        if let panel {
            lines.append("panel visible=\(panel.isVisible) frame=\(panel.frame)")
        }
        if let button = statusItem?.button, let window = button.window {
            let f = window.convertToScreen(button.convert(button.bounds, to: nil))
            lines.append("statusItem frame=\(f)")
        }
        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "mainWindow" }) {
            lines.append("main visible=\(main.isVisible) frame=\(main.frame)")
        }
        if let screen = NSScreen.main {
            lines.append("screen frame=\(screen.frame) visible=\(screen.visibleFrame) scale=\(screen.backingScaleFactor)")
        }
        try? lines.joined(separator: "\n").appending("\n")
            .write(toFile: "/tmp/ventus-frames.txt", atomically: true, encoding: .utf8)
    }
    #endif

    private func positionPanel(_ panel: NSPanel) {
        if let contentView = panel.contentView {
            contentView.layoutSubtreeIfNeeded()
            panel.setContentSize(contentView.fittingSize)
        }
        // The status item can live in menu-bar overflow (notch Macs with many
        // icons), where its window has no screen — or, on a cold path, have no
        // window at all. Fall back to the top-right corner of the main screen
        // rather than leaving the panel at a zero-origin default rect.
        let button = statusItem?.button
        let buttonWindow = button?.window
        guard let screen = buttonWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        // The window carries a transparent shadow margin on every side, so all
        // of this positions the visible CARD and converts to a window origin at
        // the end — anchoring the window instead leaves the panel reading as
        // floating away from the menu bar.
        let cardWidth = size.width

        var cardLeft = visible.maxX - 8 - cardWidth
        var anchorY = visible.maxY
        if let button, let buttonWindow, buttonWindow.screen != nil {
            let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            // Left edges flush: the panel hangs from the icon rather than
            // reaching back towards it.
            cardLeft = buttonFrame.minX
            anchorY = buttonFrame.minY
        }
        // Keep the card fully on screen — a status item near the right edge
        // would otherwise push a 330pt panel off it.
        cardLeft = max(visible.minX + 8, min(cardLeft, visible.maxX - 8 - cardWidth))

        let x = cardLeft
        let y = anchorY - size.height - 6
        // This pins the WINDOW's top edge, which now sits a shadow-inset above
        // the card's top edge.
        panelTopY = anchorY - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
