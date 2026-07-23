import Foundation

/// Minimal fan-hardware surface the HardwareOwner drives. SMCClient conforms via
/// an adapter; tests inject a fake to exercise failure/hang/unreadable paths.
public protocol FanHardware: AnyObject {
    /// Number of fans reported by hardware (0 if unreadable).
    func fanCount() -> Int
    /// A fan's hardware maximum RPM (nil if unreadable).
    func fanMax(_ fan: Int) -> Double?
    /// A fan's current mode: 0 = auto, 1 = forced (nil if unreadable).
    func readMode(_ fan: Int) -> UInt8?
    /// Sets target then forces mode — mode is forced ONLY if the target write
    /// succeeded. Returns overall success.
    @discardableResult func force(_ fan: Int, rpm: Double) -> Bool
    /// Returns a fan to auto (mode 0). Returns success.
    @discardableResult func toAuto(_ fan: Int) -> Bool
}

/// Exclusive owner of the fan hardware. Every SMC control write in the system
/// flows through this one object on its own serial queue, so the control loop,
/// watchdog, shutdown handler, and XPC commands can never interleave writes and
/// nothing is ever held across a blocking kernel call.
///
/// Design (fixes the "watchdog deadlocks behind a stalled write" flaw):
/// - `submit(_:deadline:)` enqueues a command on the owner queue and waits up to
///   `deadline` for its real result. Callers NEVER touch hardware directly.
/// - If the owner queue is wedged inside a hung `IOConnectCallStructMethod`, the
///   caller's wait times out and returns `.timedOut`. The caller (watchdog/signal)
///   then exits the process — our forced-mode claim drops on death and launchd
///   restarts us into a startup restore. Dying is the correct, always-available
///   backstop; you cannot interrupt a hung kernel call, so we never pretend to.
/// - `emergencyRestore` latches: afterwards every `apply`/`forceMax` is refused,
///   so a late control tick can never re-force fans after a rescue.
public final class HardwareOwner: @unchecked Sendable {
    public struct FanTarget: Sendable, Equatable {
        public let fan: Int
        public let rpm: Double
        public init(fan: Int, rpm: Double) {
            self.fan = fan
            self.rpm = rpm
        }
    }

    public enum Command: Sendable {
        /// Normal armed control: force each fan to its target.
        case apply([FanTarget])
        /// Thermal emergency: force EVERY fan to its own hardware max.
        case forceMaxAll
        /// Release all fans to Apple auto (no latch — used by disarm/set-auto).
        case restore
        /// Latch emergency stop and release all fans to auto. Refuses all further
        /// apply/forceMax until the process restarts.
        case emergencyRestore
    }

    public enum Result: Sendable, Equatable {
        case ok
        case refusedLatched
        case failed(String)
        case timedOut
    }

    private let hw: FanHardware
    private let logger: (String) -> Void
    private let queue = DispatchQueue(label: "com.formm.ventus.hwowner")
    private let stateLock = NSLock()
    private var latched = false
    /// Fan count captured once at init from a successful read; restore is
    /// measured against THIS, so a fan that vanishes at restore time is a
    /// failure, not a silent skip.
    private let expectedFanCount: Int

    public init(hardware: FanHardware, logger: @escaping (String) -> Void = { _ in }) {
        self.hw = hardware
        self.logger = logger
        self.expectedFanCount = max(hardware.fanCount(), 0)
        logger("[HardwareOwner] Initialized, expected fan count: \(expectedFanCount)")
    }

    public var isLatched: Bool { stateLock.withLock { latched } }

    /// Submits a command and waits up to `deadline` for its real result.
    /// Deadlock-free: the caller waits on a semaphore, never on a lock held
    /// across hardware I/O.
    @discardableResult
    public func submit(_ command: Command, deadline: TimeInterval) -> Result {
        // Reject non-emergency work before enqueue once latched (cheap fast path;
        // re-checked on the owner queue to close the enqueue-order window).
        switch command {
        case .apply, .forceMaxAll:
            if isLatched { return .refusedLatched }
        case .restore, .emergencyRestore:
            break
        }

        let sem = DispatchSemaphore(value: 0)
        var result: Result = .timedOut
        queue.async { [weak self] in
            guard let self = self else { sem.signal(); return }
            result = self.execute(command)
            sem.signal()
        }
        if sem.wait(timeout: .now() + deadline) == .timedOut {
            logger("[HardwareOwner] Command timed out after \(deadline)s (owner queue may be wedged)")
            return .timedOut
        }
        return result
    }

    // MARK: - Owner-queue execution (single-threaded by construction)

    private func execute(_ command: Command) -> Result {
        let latchedNow = stateLock.withLock { latched }
        switch command {
        case .apply(let targets):
            if latchedNow { return .refusedLatched }
            var failures: [Int] = []
            for t in targets where !hw.force(t.fan, rpm: t.rpm) {
                failures.append(t.fan)
            }
            return failures.isEmpty ? .ok : .failed("apply failed on fans \(failures)")

        case .forceMaxAll:
            if latchedNow { return .refusedLatched }
            let count = expectedFanCount > 0 ? expectedFanCount : 8
            var failures: [Int] = []
            for f in 0 ..< count {
                let maxRPM = hw.fanMax(f) ?? 6800
                if !hw.force(f, rpm: maxRPM) { failures.append(f) }
            }
            return failures.isEmpty ? .ok : .failed("forceMax failed on fans \(failures)")

        case .restore:
            return restoreAllVerified()

        case .emergencyRestore:
            stateLock.withLock { latched = true }
            logger("[HardwareOwner] EMERGENCY LATCH engaged")
            return restoreAllVerified()
        }
    }

    /// All-or-fail restore: every expected fan must read back mode 0. A fan that
    /// was expected but is now unreadable is a FAILURE (not a skip) — that's the
    /// exact case that let a forced fan slip through the old best-effort restore.
    private func restoreAllVerified() -> Result {
        let count = expectedFanCount > 0 ? expectedFanCount : 8
        var failures: [Int] = []
        var verified = 0
        for f in 0 ..< count {
            guard hw.readMode(f) != nil else {
                // Unreadable now. If we expected this fan to exist, that's a failure.
                if f < expectedFanCount { failures.append(f) }
                continue
            }
            _ = hw.toAuto(f)
            if hw.readMode(f) == 0 {
                verified += 1
            } else {
                failures.append(f)
            }
        }
        if !failures.isEmpty {
            return .failed("restore could not verify fans \(failures)")
        }
        if verified == 0 {
            return .failed("restore verified zero fans")
        }
        return .ok
    }
}
