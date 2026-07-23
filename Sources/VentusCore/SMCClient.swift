import Foundation
import IOKit
import CVentusPrivate

/// AppleSMC user client for fan telemetry and control on Apple Silicon.
///
/// Protocol (canonical, from smcFanControl/SMCKit lineage):
/// - 80-byte `VentusSMCKeyData` struct (C-defined layout), selector 2.
/// - Reads are TWO-phase: GetKeyInfo (op 9) fetches dataSize/dataType,
///   then ReadKey (op 5) fetches bytes.
/// - Writes: GetKeyInfo first, then WriteKey (op 6) with matching size.
///
/// Fan keys: F{n}Ac actual, F{n}Tg target, F{n}Mn min, F{n}Mx max,
/// F{n}Md mode (0=auto, 1=forced), FNum fan count. Types on Apple Silicon
/// are `flt ` (LE float); fpe2/ui8/ui16/ui32/sp78 supported for portability.
///
/// ALL writes flow through `checkedWrite` — the single audited choke point,
/// which clamps fan targets to the hardware [min, max] envelope.
public final class SMCClient: @unchecked Sendable {
    private let logger: (String) -> Void
    private let queue = DispatchQueue(label: "com.formm.ventus.smc")
    private let connection: io_connect_t
    private var keyInfoCache: [UInt32: VentusSMCKeyInfo] = [:]

    public init?(logger: @escaping (String) -> Void = { _ in }) {
        self.logger = logger

        let matching = IOServiceMatching("AppleSMC")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            logger("[SMCClient] Failed to find AppleSMC IOService")
            return nil
        }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == KERN_SUCCESS else {
            logger("[SMCClient] IOServiceOpen failed: \(kr)")
            return nil
        }
        self.connection = conn
        logger("[SMCClient] Connected to AppleSMC")
    }

    deinit {
        IOServiceClose(connection)
    }

    // MARK: - Low level

    private static func fourCC(_ key: String) -> UInt32? {
        let bytes = Array(key.utf8)
        guard bytes.count == 4 else { return nil }
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
             | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }

    private static func typeString(_ code: UInt32) -> String {
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                     UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    /// One kernel round-trip. Caller must be on `queue`.
    private func call(_ input: inout VentusSMCKeyData) -> VentusSMCKeyData? {
        var output = VentusSMCKeyData()
        var outputSize = MemoryLayout<VentusSMCKeyData>.size
        let kr = withUnsafePointer(to: &input) { inPtr in
            IOConnectCallStructMethod(
                connection, UInt32(kVentusSMCSelectorYPC),
                inPtr, MemoryLayout<VentusSMCKeyData>.size,
                &output, &outputSize
            )
        }
        guard kr == KERN_SUCCESS else {
            logger("[SMCClient] SMC call failed: \(kr)")
            return nil
        }
        guard output.result == 0 else {
            // result 132 = key not found (normal when probing); stay quiet for it
            if output.result != 132 {
                logger("[SMCClient] SMC op failed, result=\(output.result)")
            }
            return nil
        }
        return output
    }

    /// Two-phase: key info (cached), on `queue`.
    private func keyInfo(_ keyCode: UInt32) -> VentusSMCKeyInfo? {
        if let cached = keyInfoCache[keyCode] { return cached }
        var input = VentusSMCKeyData()
        input.key = keyCode
        input.data8 = UInt8(kVentusSMCGetKeyInfo)
        guard let out = call(&input) else { return nil }
        keyInfoCache[keyCode] = out.keyInfo
        return out.keyInfo
    }

    private func readBytes(_ key: String) -> (info: VentusSMCKeyInfo, bytes: [UInt8])? {
        guard let keyCode = Self.fourCC(key), let info = keyInfo(keyCode) else { return nil }
        var input = VentusSMCKeyData()
        input.key = keyCode
        input.keyInfo.dataSize = info.dataSize
        input.data8 = UInt8(kVentusSMCReadKey)
        guard let out = call(&input) else { return nil }
        let count = min(Int(info.dataSize), 32)
        let bytes = withUnsafeBytes(of: out.bytes) { raw in
            Array(raw.prefix(count))
        }
        return (info, bytes)
    }

    private func decode(_ info: VentusSMCKeyInfo, _ bytes: [UInt8]) -> Double? {
        switch Self.typeString(info.dataType) {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8)
                     | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: bits))
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt32(bytes[0]) << 8 | UInt32(bytes[1]))) / 4.0
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256.0
        case "ui8 ", "ui8\0":
            guard let b = bytes.first else { return nil }
            return Double(b)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt32(bytes[0]) << 8 | UInt32(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double((UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
                        | (UInt32(bytes[2]) << 8) | UInt32(bytes[3]))
        default:
            return nil
        }
    }

    private func encode(_ value: Double, as info: VentusSMCKeyInfo) -> [UInt8]? {
        switch Self.typeString(info.dataType) {
        case "flt ":
            let bits = Float(value).bitPattern
            return [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff),
                    UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)]
        case "fpe2":
            let raw = UInt16(max(0, min(65535, value * 4)))
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case "ui8 ", "ui8\0":
            return [UInt8(max(0, min(255, value)))]
        case "ui16":
            let raw = UInt16(max(0, min(65535, value)))
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        default:
            return nil
        }
    }

    /// Single audited write choke point. On `queue`. Never bypass.
    /// Clamps value into the allowed range (or skips write if range unavailable).
    /// Returns true only if the kernel write succeeded — callers gate on this.
    @discardableResult
    private func checkedWrite(_ key: String, value: Double, allowedRange: ClosedRange<Double>?) -> Bool {
        let clampedValue: Double
        if let range = allowedRange {
            clampedValue = max(range.lowerBound, min(range.upperBound, value))
            if clampedValue != value {
                logger("[SMCClient] Clamped \(key): \(value) → \(clampedValue) (range: \(range.lowerBound)–\(range.upperBound))")
            }
        } else {
            clampedValue = value
        }

        guard let keyCode = Self.fourCC(key), let info = keyInfo(keyCode),
              let bytes = encode(clampedValue, as: info) else {
            logger("[SMCClient] write \(key): no key info / unsupported type")
            return false
        }
        var input = VentusSMCKeyData()
        input.key = keyCode
        input.keyInfo.dataSize = UInt32(bytes.count)
        input.data8 = UInt8(kVentusSMCWriteKey)
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (i, b) in bytes.enumerated() where i < 32 { raw[i] = b }
        }
        guard call(&input) != nil else { return false }
        logger("[SMCClient] wrote \(key)=\(clampedValue)")
        return true
    }

    // MARK: - Public API

    /// Reads an SMC key decoded to its natural numeric value.
    public func readKey(_ key: String) -> Any? {
        queue.sync {
            guard let (info, bytes) = readBytes(key) else { return nil }
            return decode(info, bytes)
        }
    }

    public func writeKey(_ key: String, value: UInt8) {
        queue.sync { checkedWrite(key, value: Double(value), allowedRange: nil) }
    }

    public func writeKey(_ key: String, value: Float) {
        queue.sync { checkedWrite(key, value: Double(value), allowedRange: nil) }
    }

    /// Number of fans (FNum), 0 if unavailable.
    public func listFanCount() -> Int {
        queue.sync {
            guard let (info, bytes) = readBytes("FNum"),
                  let v = decode(info, bytes) else { return 0 }
            return Int(v)
        }
    }

    private func readFanKey(_ fan: Int, _ suffix: String) -> Float? {
        guard fan >= 0 && fan < 16 else { return nil }
        return queue.sync {
            guard let (info, bytes) = readBytes("F\(fan)\(suffix)"),
                  let v = decode(info, bytes) else { return nil }
            return Float(v)
        }
    }

    public func readFanActual(_ fan: Int) -> Float? { readFanKey(fan, "Ac") }
    public func readFanTarget(_ fan: Int) -> Float? { readFanKey(fan, "Tg") }
    public func readFanMin(_ fan: Int) -> Float? { readFanKey(fan, "Mn") }
    public func readFanMax(_ fan: Int) -> Float? { readFanKey(fan, "Mx") }

    /// Reads fan mode: 0 = auto (macOS controls), 1 = forced (we control).
    public func readFanMode(_ fan: Int) -> UInt8? {
        guard fan >= 0 && fan < 16 else { return nil }
        return queue.sync {
            guard let (info, bytes) = readBytes("F\(fan)Md"),
                  let v = decode(info, bytes) else { return nil }
            return UInt8(v)
        }
    }

    /// Fan mode: 0 = auto (macOS controls), 1 = forced (we control).
    /// Returns true if the write succeeded.
    @discardableResult
    public func setFanMode(_ fan: Int, mode: UInt8) -> Bool {
        guard fan >= 0 && fan < 16, mode <= 1 else { return false }
        return queue.sync {
            checkedWrite("F\(fan)Md", value: Double(mode), allowedRange: 0 ... 1)
        }
    }

    /// Writes a fan target RPM clamped to the hardware [min,max] envelope.
    /// Returns true only if the target write actually succeeded. Refuses (false)
    /// if the envelope can't be read — never writes blind. Does NOT touch mode.
    @discardableResult
    public func setFanTarget(_ fan: Int, rpm: Float) -> Bool {
        guard fan >= 0 && fan < 16 else { return false }
        return queue.sync { writeTargetLocked(fan, rpm: rpm) }
    }

    /// Caller must hold `queue`. Writes target only.
    private func writeTargetLocked(_ fan: Int, rpm: Float) -> Bool {
        guard let minB = readBytes("F\(fan)Mn"), let minV = decode(minB.info, minB.bytes),
              let maxB = readBytes("F\(fan)Mx"), let maxV = decode(maxB.info, maxB.bytes),
              minV < maxV else {
            logger("[SMCClient] REFUSED F\(fan)Tg: cannot read min/max envelope")
            return false
        }
        let clampedRPM = max(minV, min(maxV, Double(rpm)))
        if clampedRPM != Double(rpm) {
            logger("[SMCClient] F\(fan)Tg clamped: \(rpm) → \(clampedRPM)")
        }
        return checkedWrite("F\(fan)Tg", value: clampedRPM, allowedRange: nil)
    }

    /// Atomically (under the SMC queue) sets a fan's target then forces it —
    /// mode is switched to forced ONLY if the target write succeeded, so a fan
    /// is never left forced at a stale/undefined target. Returns overall success.
    @discardableResult
    public func forceFan(_ fan: Int, rpm: Float) -> Bool {
        guard fan >= 0 && fan < 16 else { return false }
        return queue.sync {
            guard writeTargetLocked(fan, rpm: rpm) else {
                logger("[SMCClient] forceFan F\(fan): target write failed, NOT forcing mode")
                return false
            }
            return checkedWrite("F\(fan)Md", value: 1, allowedRange: 0 ... 1)
        }
    }

    /// Returns fan mode to auto. Returns true if the write succeeded.
    @discardableResult
    public func restoreFan(_ fan: Int) -> Bool {
        setFanMode(fan, mode: 0)
    }
}

// MARK: - FanHardware conformance

extension SMCClient: FanHardware {
    public func fanCount() -> Int { listFanCount() }
    public func fanMax(_ fan: Int) -> Double? { readFanMax(fan).map(Double.init) }
    public func readMode(_ fan: Int) -> UInt8? { readFanMode(fan) }
    public func force(_ fan: Int, rpm: Double) -> Bool { forceFan(fan, rpm: Float(rpm)) }
    public func toAuto(_ fan: Int) -> Bool { setFanMode(fan, mode: 0) }
}
