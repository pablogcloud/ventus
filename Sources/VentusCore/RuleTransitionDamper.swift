import Foundation

/// Holds a rule-driven profile change until it has been the answer for a while.
///
/// Rule inputs are noisy in a way the rest of the pipeline is not. GPU power in
/// particular swings hard second to second — menu screens, loading, scene
/// changes — so `.gameDetected` sits right on its threshold and flips on and off
/// every control tick. Each flip swaps the entire curve, which is audible as the
/// fans surging up and down. The curve engine has hysteresis and dwell for
/// temperature, but profile *selection* upstream of it had neither.
///
/// This is deliberately not part of `RuleEngine.resolve`, which stays pure and
/// therefore trivially testable; the state lives here instead.
///
/// Not a safety regression: holding a change for `dwellS` only delays swapping
/// between curves. The curve engine still tracks temperature the whole time, and
/// the 95 °C thermal override bypasses profiles entirely — so the cooling floor
/// does not move.
public final class RuleTransitionDamper {
    /// How long a new answer must persist before it is applied. Long enough to
    /// ride out GPU power dipping across the threshold between frames, short
    /// enough that quitting a game is not followed by a noticeably long wait.
    public let dwellS: TimeInterval

    private var applied: RuleEngine.Resolution?
    private var candidate: RuleEngine.Resolution?
    private var candidateSinceUptime: TimeInterval?

    public init(dwellS: TimeInterval = 12) {
        self.dwellS = dwellS
    }

    /// What is currently in force, without advancing anything. For previews and
    /// dry runs, which must not disturb the live transition state.
    public var current: RuleEngine.Resolution? { applied }

    /// Feeds a freshly computed resolution in and returns what should actually
    /// run. Call once per control tick, on the control loop's own queue.
    public func settle(
        _ proposed: RuleEngine.Resolution,
        nowUptime: TimeInterval
    ) -> RuleEngine.Resolution {
        guard let applied else {
            self.applied = proposed
            return proposed
        }

        // Pinning and un-pinning are direct user actions. Making someone wait
        // after they click a profile — or Auto — reads as the app ignoring them,
        // so dwell governs rule-to-rule changes only.
        if proposed.isPinned || applied.isPinned {
            self.applied = proposed
            candidate = nil
            candidateSinceUptime = nil
            return proposed
        }

        // Same profile: nothing actuates, so let a changed reason through
        // immediately. Only the profile itself is rate-limited.
        if proposed.profileName == applied.profileName {
            self.applied = proposed
            candidate = nil
            candidateSinceUptime = nil
            return proposed
        }

        if candidate?.profileName != proposed.profileName {
            candidate = proposed
            candidateSinceUptime = nowUptime
            return applied
        }

        guard let since = candidateSinceUptime, nowUptime - since >= dwellS else {
            return applied
        }

        self.applied = proposed
        candidate = nil
        candidateSinceUptime = nil
        return proposed
    }
}
