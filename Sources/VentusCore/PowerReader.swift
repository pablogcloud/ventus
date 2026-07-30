import Foundation
import CVentusPrivate

/// Reads package power consumption (CPU, GPU, ANE in watts) via IOReport's
/// "Energy Model" channels (private but stable — same surface macmon/asitop use).
/// Watts are computed from energy deltas between consecutive reads, so the
/// FIRST call always returns nil (no baseline yet). Returns nil thereafter only
/// if IOReport is unavailable — callers must degrade gracefully per spec.
public final class PowerReader: @unchecked Sendable {
    private let logger: (String) -> Void
    private let queue = DispatchQueue(label: "com.formm.ventus.powerreader")

    public struct PowerReading: Equatable, Codable {
        public let cpuW: Double?
        public let gpuW: Double?
        public let aneW: Double?
        public let timestamp: Date

        public var totalW: Double {
            (cpuW ?? 0) + (gpuW ?? 0) + (aneW ?? 0)
        }
    }

    private var subscription: IOReportSubscriptionRef?
    private var subscribedChannels: CFMutableDictionary?
    private var previousSample: CFDictionary?
    private var previousSampleTime: Date?
    private var initialized = false
    private var unavailable = false

    public init(logger: @escaping (String) -> Void = { _ in }) {
        self.logger = logger
    }

    /// Drops the cached IOReport subscription so the next read re-subscribes.
    /// The subscription goes stale across sleep/wake just like the HID client;
    /// without this, package-power reads return nothing after wake.
    public func reinitialize() {
        queue.sync {
            subscription = nil
            subscribedChannels = nil
            previousSample = nil
            previousSampleTime = nil
            initialized = false
            unavailable = false
        }
        logger("[PowerReader] reinitialized (re-subscribing on next read)")
    }

    /// Reads current power consumption. nil on first call (baseline) or if unavailable.
    public func readPower() -> PowerReading? {
        queue.sync {
            initializeIfNeeded()
            guard !unavailable, let subscription, let subscribedChannels else { return nil }

            guard let sample = IOReportCreateSamples(subscription, subscribedChannels, nil) else {
                logger("[PowerReader] IOReportCreateSamples failed")
                return nil
            }
            let now = Date()
            defer {
                previousSample = sample
                previousSampleTime = now
            }

            guard let prev = previousSample, let prevTime = previousSampleTime else {
                return nil  // first call establishes the baseline
            }
            let deltaT = now.timeIntervalSince(prevTime)
            guard deltaT > 0.05 else { return nil }

            guard let delta = IOReportCreateSamplesDelta(prev, sample, nil) else { return nil }

            var cpuJ = 0.0, gpuJ = 0.0, aneJ = 0.0
            var sawAny = false
            _ = IOReportIterate(delta) { channel in
                guard let channel else { return 0 }
                let name = IOReportChannelGetChannelName(channel).map { $0.takeUnretainedValue() as String } ?? ""
                let unit = IOReportChannelGetUnitLabel(channel).map { $0.takeUnretainedValue() as String } ?? ""
                let raw = Double(IOReportSimpleGetIntegerValue(channel, 0))
                let joules = raw * Self.joulesPerUnit(unit)
                let lower = name.lowercased()
                if lower.contains("cpu") {
                    cpuJ += joules; sawAny = true
                } else if lower.contains("gpu") {
                    gpuJ += joules; sawAny = true
                } else if lower.contains("ane") {
                    aneJ += joules; sawAny = true
                }
                return 0  // continue iteration
            }
            guard sawAny else { return nil }

            return PowerReading(
                cpuW: cpuJ / deltaT,
                gpuW: gpuJ / deltaT,
                aneW: aneJ / deltaT,
                timestamp: now
            )
        }
    }

    private static func joulesPerUnit(_ unit: String) -> Double {
        switch unit.trimmingCharacters(in: .whitespaces).lowercased() {
        case "nj": return 1e-9
        case "uj", "µj": return 1e-6
        case "mj": return 1e-3
        case "j": return 1
        default: return 1e-9  // Apple Silicon energy model reports nJ by default
        }
    }

    private func initializeIfNeeded() {
        guard !initialized else { return }
        initialized = true

        guard let channels = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0) else {
            logger("[PowerReader] Energy Model channel group unavailable")
            unavailable = true
            return
        }
        var subbedUnmanaged: Unmanaged<CFMutableDictionary>?
        guard let sub = IOReportCreateSubscription(nil, channels, &subbedUnmanaged, 0, nil),
              let subbed = subbedUnmanaged?.takeUnretainedValue() else {
            logger("[PowerReader] IOReportCreateSubscription failed")
            unavailable = true
            return
        }
        // Held (not released) for the reader's lifetime; the subscription owns it.
        subscription = sub
        subscribedChannels = subbed
        logger("[PowerReader] subscribed to Energy Model channels")
    }
}
