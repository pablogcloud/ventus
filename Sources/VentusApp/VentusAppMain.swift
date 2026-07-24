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
        // The menu-bar item + popover are hosted by AppDelegate via AppKit
        // (NSStatusItem + NSPopover). SwiftUI's MenuBarExtra(.window) does NOT
        // reliably re-render its content on state changes — clicks fired but the
        // view stayed frozen (selected profile never highlighted, arm confirmation
        // never appeared). NSPopover hosts SwiftUI in a normal reactive context.
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
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar-only, no dock icon

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "fan",
                accessibilityDescription: "Ventus"
            )
            button.imagePosition = .imageLeading
            button.title = " --°"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        self.statusItem = item

        popover.behavior = .transient   // closes when you click away
        popover.animates = true
        let host = NSHostingController(
            rootView: PopoverView(
                observer: daemonClient,
                showMainWindow: .constant(false)
            )
        )
        host.sizingOptions = [.preferredContentSize]   // size the popover to the SwiftUI content
        popover.contentViewController = host

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

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            // Make the popover key so its controls receive the first click.
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
