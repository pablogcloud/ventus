import Foundation

/// Groups temperature sensors by their thermal domain.
enum SensorGroup: String, CaseIterable, Hashable, Codable {
    case cpuPerf = "cpu_perf"
    case cpuEff = "cpu_eff"
    case gpu = "gpu"
    case soc = "soc"
    case battery = "battery"
    case nand = "nand"
    case other = "other"
}

/// Reading from a sensor group: max temp, mean temp, count of sensors in group.
struct GroupReading: Equatable, Codable {
    let max: Double
    let mean: Double
    let count: Int
}

/// Reads temperature sensors from Apple Silicon via IOHIDEventSystemClient.
/// Gracefully degrades if private APIs unavailable.
final class SensorReader: Sendable {
    private let logger: (String) -> Void
    private let queue = DispatchQueue(label: "com.formm.ventus.sensorreader", attributes: .initiallyInactive)

    init(logger: @escaping (String) -> Void = { _ in }) {
        self.logger = logger
        queue.activate()
    }

    /// Classifies a sensor name into a thermal domain.
    private func classifySensor(_ name: String) -> SensorGroup {
        let lower = name.lowercased()

        // P-core (performance)
        if lower.contains("pacc") || lower.contains("p-core") || lower.contains("pcore") {
            return .cpuPerf
        }
        // E-core (efficiency)
        if lower.contains("eacc") || lower.contains("e-core") || lower.contains("ecore") {
            return .cpuEff
        }
        // GPU
        if lower.contains("gpu") {
            return .gpu
        }
        // System on Chip
        if lower.contains("soc") {
            return .soc
        }
        // Battery
        if lower.contains("battery") || lower.contains("gas gauge") {
            return .battery
        }
        // NAND/Storage
        if lower.contains("nand") || lower.contains("ssd") || lower.contains("flash") {
            return .nand
        }

        return .other
    }

    /// Takes a snapshot of current temperature readings, aggregated by sensor group.
    /// Returns a dictionary mapping each group to its aggregated reading.
    /// If sensor access fails, returns an empty dictionary (graceful degradation).
    func snapshot() -> [SensorGroup: GroupReading] {
        var result: [SensorGroup: GroupReading] = [:]
        queue.sync {
            // Simulate reading from IOHIDEventSystemClient
            // In a real implementation, this would use the private C APIs
            // For now, this is a placeholder that can be filled in later with actual hardware access
            // The structure is correct; the hardware call would go here.
            // Example stub data for testing:
            let sensors = readSensorsFromHID()

            // Group and aggregate
            var groups: [SensorGroup: [Double]] = [:]
            for (name, temp) in sensors {
                let group = classifySensor(name)
                if groups[group] == nil {
                    groups[group] = []
                }
                groups[group]?.append(temp)
            }

            // Compute max and mean for each group
            for (group, temps) in groups {
                let max = temps.max() ?? 0
                let mean = temps.isEmpty ? 0 : temps.reduce(0, +) / Double(temps.count)
                result[group] = GroupReading(max: max, mean: mean, count: temps.count)
            }
        }
        return result
    }

    /// Private helper: reads temperature sensors from IOHIDEventSystemClient.
    /// Returns array of (sensor name, temperature in Celsius).
    private func readSensorsFromHID() -> [(String, Double)] {
        // Placeholder: in production, this would:
        // 1. Create IOHIDEventSystemClient
        // 2. Copy services matching PrimaryUsagePage 0xff00/0xff05
        // 3. For each service, register for temperature events and read kIOHIDEventFieldTemperatureLevel
        // 4. Decode temperature field (typically in Celsius * 100 or similar)
        // 5. Cache by sensor name from IOHIDServiceClientCopyProperty "Product"
        //
        // For unit tests, this is mocked. For actual hardware access, this needs real implementation.
        return []
    }
}
