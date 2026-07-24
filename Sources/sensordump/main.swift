import Foundation
import CVentusPrivate
import VentusCore

// Debug tool: prints every Apple-vendor temperature HID sensor with its raw
// name, current reading, and the group SensorReader.classifySensor assigns.
// Used to validate the classifier against real hardware (see the U5 note in
// SensorReader.swift).

guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
    fatalError("IOHIDEventSystemClientCreate failed")
}
let matching: [String: Int] = [
    "PrimaryUsagePage": Int(kVentusHIDUsagePageAppleVendor),
    "PrimaryUsage": Int(kVentusHIDUsageAppleVendorTemperatureSensor),
]
IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
guard let serviceArray = IOHIDEventSystemClientCopyServices(client) else {
    fatalError("no HID services matched")
}

let reader = SensorReader()
var rows: [(name: String, temp: Double, group: String)] = []
for i in 0 ..< CFArrayGetCount(serviceArray) {
    guard let ptr = CFArrayGetValueAtIndex(serviceArray, i) else { continue }
    let service = unsafeBitCast(ptr, to: IOHIDServiceClientRef.self)
    let name = (IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String)
        ?? "unknown-\(i)"
    var celsius = Double.nan
    if let event = IOHIDServiceClientCopyEvent(
        service, Int64(kVentusHIDEventTypeTemperature), 0, 0
    ) {
        celsius = IOHIDEventGetFloatValue(event, Int32(kVentusHIDFieldTemperatureLevel))
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release()
    }
    let group = reader.classifySensor(name).map(\.rawValue) ?? "EXCLUDED"
    rows.append((name, celsius, group))
}

for row in rows.sorted(by: { $0.group == $1.group ? $0.name < $1.name : $0.group < $1.group }) {
    print(String(format: "%-12s %6.1f°C  %s",
                 (row.group as NSString).utf8String!,
                 row.temp,
                 (row.name as NSString).utf8String!))
}
print("total: \(rows.count)")
