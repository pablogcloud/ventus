import Foundation
import IOKit

/// The physical chip this Mac runs on — the die schematic draws itself from
/// these counts, so an M4 Pro shows its own core layout, not a generic one.
struct ChipInfo {
    let name: String        // e.g. "Apple M2 Max"
    let pCores: Int
    let eCores: Int
    let gpuCores: Int

    static let current = detect()

    private static func detect() -> ChipInfo {
        let name = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        // perflevel0 = performance cluster, perflevel1 = efficiency cluster.
        let pCores = sysctlInt("hw.perflevel0.physicalcpu") ?? 8
        let eCores = sysctlInt("hw.perflevel1.physicalcpu") ?? 4
        return ChipInfo(
            name: name,
            pCores: pCores,
            eCores: eCores,
            gpuCores: gpuCoreCount() ?? 16
        )
    }

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ key: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    /// GPU core count from the AGXAccelerator IORegistry entry.
    private static func gpuCoreCount() -> Int? {
        let matching = IOServiceMatching("AGXAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let value = IORegistryEntryCreateCFProperty(
            entry, "gpu-core-count" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        return (value as? NSNumber)?.intValue
    }
}
