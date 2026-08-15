import Foundation

/// Pure logic: evaluates auto-switch rules to determine active profile.
/// Returns the name of the profile that should be active.
public final class RuleEngine: Sendable {
    private let logger: (String) -> Void

    public init(logger: @escaping (String) -> Void = { _ in }) {
        self.logger = logger
    }

    /// How old a `SessionContext` may be before its facts stop counting.
    ///
    /// The app pushes every 10s, so 30s tolerates two missed pushes. Past that,
    /// session-dependent triggers are treated as not-matching rather than
    /// trusted: acting on a stale belief about what is running is how you end up
    /// holding fans at full speed for a game that quit twenty minutes ago.
    public static let maxSessionAgeS: TimeInterval = 30

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
        /// False when the session facts above are stale or were never received.
        /// Time-based rules ignore this; everything else declines to match.
        var sessionIsFresh: Bool = true
    }

    /// What the daemon should run, and why.
    public struct Resolution: Equatable, Sendable {
        public let profileName: String
        /// Human-readable description of the rule that won, for the UI and
        /// `ventusctl status`. Nil when pinned manually or falling back.
        public let ruleLabel: String?
        public let isPinned: Bool

        public init(profileName: String, ruleLabel: String?, isPinned: Bool) {
            self.profileName = profileName
            self.ruleLabel = ruleLabel
            self.isPinned = isPinned
        }
    }

    /// The one entry point the daemon calls each control tick. Everything it
    /// needs to decide lives in the arguments, so it is directly testable.
    ///
    /// - Parameter sessionAgeS: seconds since the context was received, measured
    ///   on a sleep-excluding clock. Nil means nothing has ever arrived.
    public func resolve(
        config: Config,
        session: SessionContext?,
        sessionAgeS: TimeInterval?,
        gpuWatts: Double?,
        now: Date
    ) -> Resolution {
        let knownProfiles = Set(config.profiles.keys)

        // A manual pick suspends automation entirely, until the user chooses
        // Auto again. Nothing surprises them by moving underneath.
        if let pinned = config.pinnedProfile, knownProfiles.contains(pinned) {
            return Resolution(profileName: pinned, ruleLabel: nil, isPinned: true)
        }

        let fresh = session != nil && (sessionAgeS ?? .infinity) <= Self.maxSessionAgeS
        let s = session ?? SessionContext()
        let context = RuleContext(
            onBattery: s.onBattery,
            clamshellClosed: s.clamshellClosed,
            externalDisplayConnected: s.externalDisplayConnected,
            runningBundleIDs: s.runningBundleIDs,
            frontmostBundleID: s.frontmostBundleID,
            frontmostIsFullscreen: s.frontmostIsFullscreen,
            gpuPowerW: gpuWatts,
            localTime: now,
            sessionIsFresh: fresh
        )

        let threshold = config.rules.gameGPUWattsThreshold
            ?? ChipInfo.current.defaultGameGPUWatts

        for rule in config.rules.rules.sorted(by: { $0.priority > $1.priority }) {
            guard knownProfiles.contains(rule.profileName) else { continue }
            if matches(rule.trigger, context: context, gameGPUWattsThreshold: threshold) {
                return Resolution(
                    profileName: rule.profileName,
                    ruleLabel: rule.trigger.displayDescription,
                    isPinned: false
                )
            }
        }

        return Resolution(profileName: "balanced", ruleLabel: nil, isPinned: false)
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

        let threshold = rulesConfig.gameGPUWattsThreshold
            ?? ChipInfo.current.defaultGameGPUWatts

        // First matching rule wins
        for rule in sorted {
            if matches(rule.trigger, context: context, gameGPUWattsThreshold: threshold) {
                logger("[RuleEngine] Rule matched: \(rule.profileName) (priority \(rule.priority))")
                return rule.profileName
            }
        }

        // Fallback: return first profile or "balanced"
        return "balanced"
    }

    /// Checks if a trigger condition is met.
    private func matches(
        _ trigger: RuleTrigger,
        context: RuleContext,
        gameGPUWattsThreshold: Double
    ) -> Bool {
        // Only the clock is trustworthy without a fresh session.
        if !context.sessionIsFresh, trigger.needsSessionContext {
            return false
        }

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
            return isGameDetected(context: context, threshold: gameGPUWattsThreshold)

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

    /// Heuristic: game detected if frontmost app is fullscreen + sustained high
    /// GPU power. The threshold is scaled to the chip rather than fixed, since
    /// a base M3's GPU never reaches what an M2 Max draws.
    private func isGameDetected(context: RuleContext, threshold: Double) -> Bool {
        guard context.frontmostIsFullscreen else { return false }
        guard let gpuW = context.gpuPowerW else { return false }
        return gpuW > threshold
    }
}
