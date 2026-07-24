import Foundation

/// Pure logic: evaluates auto-switch rules to determine active profile.
/// Returns the name of the profile that should be active.
public final class RuleEngine: Sendable {
    private let logger: (String) -> Void

    public init(logger: @escaping (String) -> Void = { _ in }) {
        self.logger = logger
    }

    /// Context needed to evaluate rules.
public struct RuleContext: Equatable {
        let onBattery: Bool
        let clamshellClosed: Bool
        let externalDisplayConnected: Bool
        let runningBundleIDs: Set<String>
        let frontmostBundleID: String?
        let frontmostIsFullscreen: Bool
        let gpuPowerW: Double?
        let localTime: Date
    }

    /// Evaluates rules in priority order and returns the active profile name.
    /// Manual pin overrides all rules.
    public func evaluateRules(
        rulesConfig: RulesConfig,
        context: RuleContext,
        manualPin: String?,
        knownProfiles: Set<String>
    ) -> String {
        // Manual pin overrides all
        if let pinned = manualPin, knownProfiles.contains(pinned) {
            return pinned
        }

        // Sort rules by priority (descending)
        let sorted = rulesConfig.rules.sorted { $0.priority > $1.priority }

        // First matching rule wins
        for rule in sorted {
            if matches(rule.trigger, context: context) {
                logger("[RuleEngine] Rule matched: \(rule.profileName) (priority \(rule.priority))")
                return rule.profileName
            }
        }

        // Fallback: return first profile or "balanced"
        return "balanced"
    }

    /// Checks if a trigger condition is met.
    private func matches(_ trigger: RuleTrigger, context: RuleContext) -> Bool {
        switch trigger {
        case .onBattery:
            return context.onBattery

        case .onAC:
            return !context.onBattery

        case .clamshellClosed:
            return context.clamshellClosed

        case .externalDisplayConnected:
            return context.externalDisplayConnected

        case .appRunning(let bundleId):
            return context.runningBundleIDs.contains(bundleId)

        case .gameDetected:
            return isGameDetected(context: context)

        case .timeWindow(let startHour, let endHour):
            let calendar = Calendar.current
            let hour = calendar.component(.hour, from: context.localTime)

            // Handle window that wraps midnight (e.g., 22-7 means 22:00-06:59)
            if startHour <= endHour {
                // Normal case: 9-17 (9 AM to 5 PM)
                return hour >= startHour && hour < endHour
            } else {
                // Wrapping case: 22-7 (10 PM to 7 AM) - matches hour >= 22 OR hour < 7
                return hour >= startHour || hour < endHour
            }
        }
    }

    /// Heuristic: game detected if frontmost app is fullscreen + sustained high GPU power.
    private func isGameDetected(context: RuleContext) -> Bool {
        guard context.frontmostIsFullscreen else { return false }

        // Simple heuristic: GPU power >50W
        if let gpuW = context.gpuPowerW, gpuW > 50.0 {
            return true
        }

        return false
    }
}
