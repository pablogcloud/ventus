import Foundation
import IOKit

/// The physical chip this Mac runs on — the die schematic draws itself from
/// these counts, so an M4 Pro shows its own core layout, not a generic one.
///
/// Lives in VentusCore rather than the app because the daemon needs `gpuCores`
/// to scale the game-detection power threshold to this machine.
public struct ChipInfo: Sendable {
    public let name: String        // e.g. "Apple M2 Max"
    public let pCores: Int
    public let eCores: Int
    public let gpuCores: Int

    public static let current = detect()

    /// GPU power that means "something is really using the GPU", scaled to this
    /// chip. Apple Silicon GPUs draw roughly 1.2–1.5 W per core flat out, so
    /// this sits at about two thirds of peak: high enough to exclude ordinary
    /// desktop work, low enough that a real game reliably crosses it.
    ///
    /// The previous hardcoded 50 W was near an M2 Max's *peak*, which meant the
    /// rule could never fire on a smaller chip — a base M3 tops out well below
    /// it.
    public var defaultGameGPUWatts: Double {
        max(6, Double(gpuCores) * 0.9)
    }

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
