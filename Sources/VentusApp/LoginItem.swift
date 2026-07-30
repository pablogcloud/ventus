import Foundation
import ServiceManagement
import os.log

/// Launch-at-login for the menu-bar app, backed by SMAppService (macOS 13+).
/// The registration is persisted by the system — this type only reads and
/// toggles it. On macOS 12 it degrades to unavailable.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isAvailable = false

    private let log = Logger(subsystem: "com.formm.ventus.app", category: "loginitem")

    init() {
        if #available(macOS 13.0, *) {
            isAvailable = true
            refresh()
        }
    }

    func refresh() {
        guard #available(macOS 13.0, *) else { return }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app as a login item. Returns false (and
    /// leaves state unchanged) if the system rejects it.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            refresh()
            return true
        } catch {
            log.error("login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription, privacy: .public)")
            refresh()
            return false
        }
    }
}
