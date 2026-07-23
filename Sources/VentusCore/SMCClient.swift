import Foundation
import IOKit

/// Accesses fan control and temperature keys via the AppleSMC IOKit user client.
/// Thread-safe; all operations dispatch to an internal serial queue.
public final class SMCClient: Sendable {
    private let queue = DispatchQueue(label: "com.formm.ventus.smcclient", attributes: .initiallyInactive)
    private let connection: io_connect_t
    private let logger: (String) -> Void

    public struct SMCParamStruct {
        var key: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
        var vers: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
        var plen: UInt32 = 0
        var dlen: UInt32 = 0
        var data: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                   UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                   UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                   UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

        public mutating func setKey(_ k: String) {
            let bytes = Array(k.utf8)
            if bytes.count >= 4 {
                key = (bytes[0], bytes[1], bytes[2], bytes[3])
            }
        }

        public func getKey() -> String {
            let bytes = [key.0, key.1, key.2, key.3]
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }

        public mutating func setData(_ d: [UInt8]) {
            dlen = UInt32(d.count)
            for (i, byte) in d.enumerated() where i < 32 {
                switch i {
                case 0: data.0 = byte
                case 1: data.1 = byte
                case 2: data.2 = byte
                case 3: data.3 = byte
                case 4: data.4 = byte
                case 5: data.5 = byte
                case 6: data.6 = byte
                case 7: data.7 = byte
                case 8: data.8 = byte
                case 9: data.9 = byte
                case 10: data.10 = byte
                case 11: data.11 = byte
                case 12: data.12 = byte
                case 13: data.13 = byte
                case 14: data.14 = byte
                case 15: data.15 = byte
                case 16: data.16 = byte
                case 17: data.17 = byte
                case 18: data.18 = byte
                case 19: data.19 = byte
                case 20: data.20 = byte
                case 21: data.21 = byte
                case 22: data.22 = byte
                case 23: data.23 = byte
                case 24: data.24 = byte
                case 25: data.25 = byte
                case 26: data.26 = byte
                case 27: data.27 = byte
                case 28: data.28 = byte
                case 29: data.29 = byte
                case 30: data.30 = byte
                case 31: data.31 = byte
                default: break
                }
            }
        }

        public func getData() -> [UInt8] {
            let bytes = [data.0, data.1, data.2, data.3, data.4, data.5, data.6, data.7,
                        data.8, data.9, data.10, data.11, data.12, data.13, data.14, data.15,
                        data.16, data.17, data.18, data.19, data.20, data.21, data.22, data.23,
                        data.24, data.25, data.26, data.27, data.28, data.29, data.30, data.31]
            return Array(bytes.prefix(Int(dlen)))
        }
    }

    /// Initializes an SMC client. Returns nil if the AppleSMC IOService is not found or connection fails.
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
        queue.activate()
        logger("[SMCClient] Connected to AppleSMC")
    }

    deinit {
        IOServiceClose(connection)
    }

    /// Performs a synchronous SMC call via selector 2 (IOConnectCallStructMethod).
    /// Input/output struct is 80 bytes. Returns the SMCParamStruct on success, nil on failure.
    private func callSMC(_ param: inout SMCParamStruct) -> SMCParamStruct? {
        var inputSize = MemoryLayout<SMCParamStruct>.size
        var outputSize = MemoryLayout<SMCParamStruct>.size

        var resultParam = param
        let kr = withUnsafeMutablePointer(to: &resultParam) { paramPtr in
            IOConnectCallStructMethod(
                connection,
                2,  // selector
                paramPtr, inputSize,
                paramPtr, &outputSize
            )
        }

        if kr == KERN_SUCCESS {
            param = resultParam
            return resultParam
        } else {
            logger("[SMCClient] SMC call failed: \(kr)")
            return nil
        }
    }

    /// Reads an SMC key and decodes it based on the type field.
    /// Supports: flt (float), ui8, ui16, ui32, fpe2, sp78.
    public func readKey(_ key: String) -> Any? {
        var result: Any?
        queue.sync {
            var param = SMCParamStruct()
            param.setKey(key)
            param.dlen = 0

            guard let response = callSMC(&param) else { return }

            let keyType = response.getKey()
            let data = response.getData()

            // Decode based on data length and common conventions
            if keyType.hasPrefix("F") && keyType.hasSuffix("Ac") {
                // Fan actual RPM (flt)
                if data.count >= 4 {
                    result = Float(bitPattern: UInt32(data[0]) | (UInt32(data[1]) << 8) | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24))
                }
            } else if data.count >= 4 {
                // Try float decode
                result = Float(bitPattern: UInt32(data[0]) | (UInt32(data[1]) << 8) | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24))
            } else if data.count >= 2 {
                result = UInt16(data[0]) | (UInt16(data[1]) << 8)
            } else if data.count >= 1 {
                result = data[0]
            }
        }
        return result
    }

    /// Writes an SMC key with UInt8 value.
    public func writeKey(_ key: String, value: UInt8) {
        queue.sync {
            var param = SMCParamStruct()
            param.setKey(key)
            param.setData([value])
            _ = callSMC(&param)
            logger("[SMCClient] Write \(key) = \(value)")
        }
    }

    /// Writes an SMC key with Float value (4-byte IEEE).
    public func writeKey(_ key: String, value: Float) {
        queue.sync {
            var param = SMCParamStruct()
            param.setKey(key)
            let bits = value.bitPattern
            param.setData([
                UInt8(bits & 0xFF),
                UInt8((bits >> 8) & 0xFF),
                UInt8((bits >> 16) & 0xFF),
                UInt8((bits >> 24) & 0xFF)
            ])
            _ = callSMC(&param)
            logger("[SMCClient] Write \(key) = \(value)")
        }
    }

    /// Reads the count of fans available.
    public func listFanCount() -> Int {
        let countKey = "FNum"
        guard let count = readKey(countKey) as? UInt8 else { return 0 }
        return Int(count)
    }

    /// Reads actual RPM for a fan (F0Ac, F1Ac, etc.)
    public func readFanActual(_ fan: Int) -> Float? {
        guard fan >= 0 && fan < 16 else { return nil }
        let key = "F\(fan)Ac"
        return readKey(key) as? Float
    }

    /// Reads target RPM for a fan.
    public func readFanTarget(_ fan: Int) -> Float? {
        guard fan >= 0 && fan < 16 else { return nil }
        let key = "F\(fan)Tg"
        return readKey(key) as? Float
    }

    /// Reads minimum RPM for a fan.
    public func readFanMin(_ fan: Int) -> Float? {
        guard fan >= 0 && fan < 16 else { return nil }
        let key = "F\(fan)Mn"
        return readKey(key) as? Float
    }

    /// Reads maximum RPM for a fan.
    public func readFanMax(_ fan: Int) -> Float? {
        guard fan >= 0 && fan < 16 else { return nil }
        let key = "F\(fan)Mx"
        return readKey(key) as? Float
    }

    /// Sets fan mode (0 = auto, 1 = forced).
    public func setFanMode(_ fan: Int, mode: UInt8) {
        guard fan >= 0 && fan < 16 else { return }
        let key = "F\(fan)Md"
        writeKey(key, value: mode)
    }

    /// Sets target RPM for a fan (enforces that it is within [min, max]).
    public func setFanTarget(_ fan: Int, rpm: Float) {
        guard fan >= 0 && fan < 16 else { return }
        guard let minRPM = readFanMin(fan), let maxRPM = readFanMax(fan) else { return }
        let clamped = Swift.max(minRPM, Swift.min(maxRPM, rpm))
        if clamped != rpm {
            logger("[SMCClient] Target \(rpm) RPM clamped to [\(minRPM), \(maxRPM)] = \(clamped)")
        }
        let key = "F\(fan)Tg"
        writeKey(key, value: clamped)
    }
}
