import Foundation
import os.log

/// Safety state machine that sits above the curve engine.
/// Enforces hard override, observe/armed gating, and watchdogs.
/// Thread-safe: all mutable state protected by internal locks.
public final class SafetySupervisor: Sendable {
    /// Thermal emergency: any sensor ≥95°C or thermal state critical.
    private let thermalThresholdC = 95.0

    private let logger: (String) -> Void

    /// If false, engine commands are computed but never written.
    private var armed: Bool = false

    /// Thermal override in effect.
    private var thermalOverride: Bool = false

    /// Last heartbeat time from the control loop.
    private var lastHeartbeat: Date?

    /// Last CPU usage reading.
    private var lastCPUReading: (timestamp: Date, rusageSecs: Double)?

    /// FIX #9: Thread-safety lock for mutable state
    private let lock = NSLock()

    public init(armed: Bool = false, logger: @escaping (String) -> Void = { _ in }) {
        self.armed = armed
        self.logger = logger
    }

    /// Sets observe/armed mode.
    public func setArmed(_ newArmed: Bool) {
        lock.withLock {
            armed = newArmed
            logger("[SafetySupervisor] Armed mode: \(armed)")
        }
    }

    /// Returns whether the supervisor allows hardware writes.
    public func canWrite() -> Bool {
        return lock.withLock {
            return armed && !thermalOverride
        }
    }

    /// Records a heartbeat from the control loop.
    /// FIX #9: Thread-safe heartbeat recording
    public func recordHeartbeat(_ now: Date) {
        lock.withLock {
            lastHeartbeat = now
        }
    }

    /// Checks if the watchdog has detected a stall (>threshold seconds since heartbeat).
    public func isControlLoopStalled(now: Date, threshold: TimeInterval = 10.0) -> Bool {
        return lock.withLock {
            guard let last = lastHeartbeat else { return false }
            return now.timeIntervalSince(last) > threshold
        }
    }

    /// Updates thermal override based on sensor readings and thermal state.
    public func updateThermalOverride(sensors: [SensorGroup: GroupReading], thermalState: ThermalState) {
        lock.withLock {
            let maxTemp = sensors.values.map { $0.max }.max() ?? 0
            let thermalEmergency = maxTemp >= thermalThresholdC || thermalState == .critical

            if thermalEmergency && !thermalOverride {
                thermalOverride = true
                logger("[SafetySupervisor] THERMAL OVERRIDE: maxTemp=\(maxTemp)°C or critical state")
            } else if !thermalEmergency && thermalOverride {
                thermalOverride = false
                logger("[SafetySupervisor] Thermal override cleared")
            }
        }
    }

    /// Returns the required safety override RPM value (100% of max) or 0 if no override.
    public func getSafetyOverrideRPM(maxRPM: Double, sensors: [SensorGroup: GroupReading], thermalState: ThermalState) -> Double {
        updateThermalOverride(sensors: sensors, thermalState: thermalState)
        return lock.withLock {
            return thermalOverride ? maxRPM : 0
        }
    }

    /// Explicit thermal decision. Callers MUST branch on this, never on
    /// "RPM > 0" — a valid fan curve may legitimately end at 0 RPM, which would
    /// alias with "no emergency" and silently disable the override.
    public enum ThermalDecision: Equatable, Sendable {
        case normal
        case forceMax
    }

    /// Evaluates thermal state into an explicit decision (no sentinel value).
    public func thermalDecision(sensors: [SensorGroup: GroupReading], thermalState: ThermalState) -> ThermalDecision {
        updateThermalOverride(sensors: sensors, thermalState: thermalState)
        return lock.withLock { thermalOverride ? .forceMax : .normal }
    }

    /// Records CPU usage (from getrusage). Detects sustained high CPU usage.
    /// FIX #9: Thread-safe CPU reading recording
    public func updateCPUUsage(rusageSecs: Double, now: Date) {
        lock.withLock {
            lastCPUReading = (now, rusageSecs)
        }
    }

    /// Checks if daemon has sustained >5% CPU over 60s.
    public func isSelfCPUHigh(now: Date, threshold: Double = 0.05, window: TimeInterval = 60) -> Bool {
        return lock.withLock {
            guard let (oldTime, oldUsage) = lastCPUReading else { return false }

            let deltaS = now.timeIntervalSince(oldTime)
            guard deltaS >= window else { return false }

            // Rough estimate: if CPU usage is >5% of elapsed time, it's excessive
            let CPUPercent = oldUsage / deltaS
            return CPUPercent > threshold
        }
    }
}

// MARK: - Watchdog Helper

/// Watchdog: monitors heartbeat to detect stalled control loop.
/// Thread-safe: all state protected by lock.
public final class ControlLoopWatchdog: Sendable {
    private let stallThresholdS: TimeInterval
    private var lastHeartbeat: Date
    private let logger: (String) -> Void
    /// FIX #9: Lock for thread-safe heartbeat access
    private let lock = NSLock()

    public init(stallThresholdS: TimeInterval = 10.0, logger: @escaping (String) -> Void = { _ in }) {
        self.stallThresholdS = stallThresholdS
        self.lastHeartbeat = Date()
        self.logger = logger
    }

    /// Records a heartbeat from the control loop (no parameter — uses current time).
    public func recordHeartbeat() {
        lock.withLock {
            lastHeartbeat = Date()
        }
    }

    /// Checks if the loop is stalled.
    public func isStalled(now: Date) -> Bool {
        return lock.withLock {
            return now.timeIntervalSince(lastHeartbeat) > stallThresholdS
        }
    }

    /// Returns seconds since last heartbeat.
    public func secondsSinceHeartbeat(now: Date) -> TimeInterval {
        return lock.withLock {
            return now.timeIntervalSince(lastHeartbeat)
        }
    }
}

// MARK: - Self-CPU Watchdog

/// Monitors daemon's own CPU usage via rusage deltas.
/// Trips if sustained >5% over 60 seconds.
/// Thread-safe: all state protected by lock.
public final class SelfCPUWatchdog: Sendable {
    private let cpuThreshold = 0.05
    private let windowS = 60.0
    private let logger: (String) -> Void

    private var readings: [(timestamp: Date, rusageSecs: Double)] = []
    /// FIX #9: Lock for thread-safe readings access
    private let lock = NSLock()

    public init(logger: @escaping (String) -> Void = { _ in }) {
        self.logger = logger
    }

    /// Records a CPU usage sample (accumulated user + system seconds from rusage).
    public func recordSample(_ rusageSecs: Double, at now: Date) {
        lock.withLock {
            readings.append((now, rusageSecs))

            // Keep only samples within the window
            let cutoff = now.addingTimeInterval(-windowS)
            readings.removeAll { $0.timestamp < cutoff }
        }
    }

    /// Checks if the daemon is using >5% CPU sustained over the window.
    public func isHighCPU(now: Date) -> Bool {
        return lock.withLock {
            guard readings.count >= 2 else { return false }

            let oldest = readings.first!
            let newest = readings.last!

            let elapsedS = newest.timestamp.timeIntervalSince(oldest.timestamp)
            guard elapsedS >= windowS * 0.8 else { return false }  // Need most of window

            let cpuUsageS = newest.rusageSecs - oldest.rusageSecs
            let cpuPercent = cpuUsageS / elapsedS
            return cpuPercent > cpuThreshold
        }
    }

    /// Returns the measured CPU percent (for logging/debugging).
    public func measureCPUPercent(now: Date) -> Double {
        return lock.withLock {
            guard readings.count >= 2 else { return 0 }

            let oldest = readings.first!
            let newest = readings.last!

            let elapsedS = newest.timestamp.timeIntervalSince(oldest.timestamp)
            guard elapsedS > 0 else { return 0 }

            let cpuUsageS = newest.rusageSecs - oldest.rusageSecs
            return cpuUsageS / elapsedS
        }
    }
}

// MARK: - NSLock convenience extension

extension NSLock {
    /// Performs a closure while holding the lock.
    func withLock<T>(_ block: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try block()
    }
}
