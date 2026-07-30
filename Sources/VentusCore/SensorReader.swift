import Foundation
import CVentusPrivate

/// Groups temperature sensors by their thermal domain.
public enum SensorGroup: String, CaseIterable, Hashable, Codable {
    case cpuPerf = "cpu_perf"
    case cpuEff = "cpu_eff"
    case gpu = "gpu"
    case soc = "soc"
    case battery = "battery"
    case nand = "nand"
    case other = "other"
}

/// Reading from a sensor group: max temp, mean temp, count of sensors in group.
public struct GroupReading: Equatable, Codable {
    public let max: Double
    public let mean: Double
    public let count: Int

    public init(max: Double, mean: Double, count: Int) {
        self.max = max
        self.mean = mean
        self.count = count
    }
}

/// Reads temperature sensors on Apple Silicon via the private IOHIDEventSystemClient
/// surface (the same one Stats/macmon use). Gracefully degrades to an empty snapshot
/// if the interface is unavailable.
public final class SensorReader: @unchecked Sendable {
    private let logger: (String) -> Void
    private let queue = DispatchQueue(label: "com.formm.ventus.sensorreader")

    /// HID client + discovered services, created once and reused across snapshots.
    /// serviceArray is kept retained for the reader's lifetime: the elements of
    /// `services` are owned by it.
    private var client: IOHIDEventSystemClientRef?
    private var serviceArray: CFArray?
    private var services: [(name: String, service: IOHIDServiceClientRef)] = []
    private var initialized = false

    public init(logger: @escaping (String) -> Void = { _ in }) {
        self.logger = logger
    }

    /// Tears down the cached IOHIDEventSystemClient so the next snapshot rebuilds
    /// it. The client and its discovered service handles go STALE across a system
    /// sleep/wake — after wake, reads from the dead services return nothing and
    /// temperature detection silently dies until this is called. Invoked on wake
    /// and as a self-heal when all critical sensor groups vanish.
    public func reinitialize() {
        queue.sync {
            // IOHIDEventSystemClientRef is a raw `struct *` (NOT an ARC-managed
            // CF type), and Create returns +1 — nil-assignment alone would leak
            // it on every call. Release explicitly. serviceArray IS a CFArrayRef
            // (ARC-managed) and owns the service handles, so nil-ing it releases
            // those.
            if let client {
                // Balance the +1 from IOHIDEventSystemClientCreate. The ref
                // imports as OpaquePointer (raw, not ARC-managed), so release
                // via Unmanaged — same pattern snapshot() uses for its events.
                Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(client)).release()
            }
            client = nil
            serviceArray = nil
            services = []
            initialized = false
        }
        logger("[SensorReader] reinitialized (rebuilding HID client on next read)")
    }

    /// Classifies a sensor name into a thermal domain.
    ///
    /// Verified on this M2 Max (Mac14,6) 2026-07-23 — real HID names are:
    ///   "PMU tdie0".."PMU tdie10"  → SoC die temperature sensors
    ///   "PMU TP0s"/"PMU TP1s"...   → CPU P-cluster sensors ('s' suffix)
    ///   "PMU TP1g"/"PMU TP2g"...   → GPU cluster sensors ('g' suffix)
    ///   "PMU tdev1".."PMU tdev8"   → board/device temps
    ///   "PMU tcal"                 → calibration reference (~59°C constant, MUST be excluded)
    ///   "NAND CH0 temp", "gas gauge battery"
    /// The older "pACC/eACC/GPU MTR" patterns (M1-era) are kept as fallbacks.
    /// s/g suffix mapping is heuristic pending empirical validation under load (U5).
    /// Returns nil for sensors that must be excluded entirely.
    public func classifySensor(_ name: String) -> SensorGroup? {
        let lower = name.lowercased()
        if lower.contains("tcal") {
            return nil  // calibration reference, not a thermal reading
        }
        if lower.contains("pacc") || lower.contains("p-core") || lower.contains("pcore") {
            return .cpuPerf
        }
        if lower.contains("eacc") || lower.contains("e-core") || lower.contains("ecore") {
            return .cpuEff
        }
        if lower.contains("gpu") {
            return .gpu
        }
        if lower.contains("tdie") || lower.contains("soc") {
            return .soc
        }
        if lower.hasPrefix("pmu tp") {
            if lower.hasSuffix("g") { return .gpu }
            if lower.hasSuffix("s") { return .cpuPerf }
            return .soc
        }
        if lower.contains("battery") || lower.contains("gas gauge") {
            return .battery
        }
        if lower.contains("nand") || lower.contains("ssd") || lower.contains("flash") {
            return .nand
        }
        return .other
    }

    /// Takes a snapshot of current temperature readings, aggregated by sensor group.
    /// Returns an empty dictionary if sensor access fails (graceful degradation).
    public func snapshot() -> [SensorGroup: GroupReading] {
        detailedSnapshot().groups
    }

    /// Aggregates plus every individual reading (group, °C) — the UI's die heat
    /// map tints per-sensor tiles from the detail list.
    public func detailedSnapshot() -> (
        groups: [SensorGroup: GroupReading],
        details: [(group: SensorGroup, celsius: Double)]
    ) {
        queue.sync {
            initializeIfNeeded()

            var details: [(group: SensorGroup, celsius: Double)] = []
            var groups: [SensorGroup: [Double]] = [:]
            for (name, service) in services {
                guard let event = IOHIDServiceClientCopyEvent(
                    service, Int64(kVentusHIDEventTypeTemperature), 0, 0
                ) else { continue }
                let celsius = IOHIDEventGetFloatValue(event, Int32(kVentusHIDFieldTemperatureLevel))
                // CopyEvent returns +1; balance it.
                Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release()

                // Discard implausible readings (dead sensors report 0 or extremes).
                guard celsius > -40, celsius < 130, celsius != 0 else { continue }
                guard let group = classifySensor(name) else { continue }
                groups[group, default: []].append(celsius)
                details.append((group: group, celsius: celsius))
            }

            var result: [SensorGroup: GroupReading] = [:]
            for (group, temps) in groups {
                let maxT = temps.max() ?? 0
                let meanT = temps.reduce(0, +) / Double(temps.count)
                result[group] = GroupReading(max: maxT, mean: meanT, count: temps.count)
            }
            return (groups: result, details: details)
        }
    }

    /// Creates the HID client and discovers temperature services once.
    private func initializeIfNeeded() {
        guard !initialized else { return }
        initialized = true

        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            logger("[SensorReader] IOHIDEventSystemClientCreate failed")
            return
        }
        self.client = client

        let matching: [String: Int] = [
            "PrimaryUsagePage": Int(kVentusHIDUsagePageAppleVendor),
            "PrimaryUsage": Int(kVentusHIDUsageAppleVendorTemperatureSensor),
        ]
        IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)

        guard let serviceArray = IOHIDEventSystemClientCopyServices(client) else {
            logger("[SensorReader] no HID services matched")
            return
        }
        self.serviceArray = serviceArray

        let count = CFArrayGetCount(serviceArray)
        for i in 0 ..< count {
            guard let ptr = CFArrayGetValueAtIndex(serviceArray, i) else { continue }
            let service = unsafeBitCast(ptr, to: IOHIDServiceClientRef.self)
            guard let nameRef = IOHIDServiceClientCopyProperty(service, "Product" as CFString) else {
                continue
            }
            let name = (nameRef as? String) ?? "unknown-\(i)"
            services.append((name: name, service: service))
        }
        logger("[SensorReader] discovered \(services.count) temperature sensors")
    }
}
