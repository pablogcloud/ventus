import SwiftUI
import AppKit
import Combine

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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let daemonClient = DaemonClientObserver()
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

        // Debug hook: lets local tooling open UI surfaces when accessibility
        // clicking is unavailable. Active only if ~/.ventus-debug exists.
        if FileManager.default.fileExists(
            atPath: NSString(string: "~/.ventus-debug").expandingTildeInPath
        ) {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.formm.ventus.debug.command"),
                object: nil,
                queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch note.object as? String {
                    case "showPopover":
                        self.showPanel()
                    case "hidePopover":
                        self.closePanel()
                    default:
                        break
                    }
                }
            }
        }

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

        // Keep the menu-bar title in sync with the hottest temperature.
        daemonClient.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                let hottest = status?.sensors.map(\.maxTemp).max()
                let text = hottest.map { String(format: " %.0f°", $0) } ?? " --°"
                self?.statusItem?.button?.title = text
            }
            .store(in: &cancellables)
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        if panel?.isVisible == true {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        positionPanel(panel)
        NSApp.activate(ignoringOtherApps: true)
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
        panel?.orderOut(nil)
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingController(
            rootView: PopoverView(
                observer: daemonClient,
                showMainWindow: .constant(false)
            )
        )
        host.sizingOptions = [.preferredContentSize]

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentViewController = host
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        host.view.layoutSubtreeIfNeeded()
        panel.setContentSize(host.view.fittingSize)
        self.panel = panel
        return panel
    }

    private func positionPanel(_ panel: NSPanel) {
        if let contentView = panel.contentViewController?.view {
            contentView.layoutSubtreeIfNeeded()
            panel.setContentSize(contentView.fittingSize)
        }
        guard let button = statusItem?.button, let buttonWindow = button.window else {
            return
        }
        // The status item can live in menu-bar overflow (notch Macs with many
        // icons), where its window has no screen — fall back to the main screen
        // and anchor to the top-right corner.
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        let anchorX = buttonWindow.screen != nil ? buttonFrame.maxX : visible.maxX
        let anchorY = buttonWindow.screen != nil ? buttonFrame.minY : visible.maxY
        var x = anchorX - size.width
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
        let y = anchorY - size.height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
