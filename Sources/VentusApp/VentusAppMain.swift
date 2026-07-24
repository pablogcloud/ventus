import SwiftUI

@main
struct VentusApp: App {
    @StateObject private var daemonClient = DaemonClientObserver()
    @State private var showMainWindow = false

    init() {
        VentusTheme.registerFonts()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(observer: daemonClient, showMainWindow: $showMainWindow)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "fan")
                    .foregroundStyle(VentusPalette.accent)
                Text(menuBarTemperature)
                    .font(VentusFont.number(12, weight: .semibold))
                    .foregroundStyle(VentusPalette.ink)
            }
        }
        .menuBarExtraStyle(.window)

        Window("Ventus", id: "mainWindow") {
            MainWindowView(observer: daemonClient)
        }
        .windowStyle(.hiddenTitleBar)
        .keyboardShortcut("1", modifiers: .command)
    }

    private var menuBarTemperature: String {
        guard let hottest = daemonClient.status?.sensors.map(\.maxTemp).max() else {
            return "--°"
        }
        return String(format: "%.0f°", hottest)
    }
}
