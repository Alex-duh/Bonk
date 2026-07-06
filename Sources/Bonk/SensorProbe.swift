import Foundation
import IOKit.hid

// Terminal diagnostic: `/Applications/Bonk.app/Contents/MacOS/Bonk --probe`
// Opens EVERY SPU sensor device (vendor page 0xFF00), requests a report
// interval, and counts reports per device for 5 seconds. Distinguishes
// "the accelerometer is dormant" from "no SPU sensor streams at all" on a
// given Mac model — some models stream to any client, others never do.
enum SensorProbe {
    private struct Entry {
        let usage: Int
        let product: String
        let productID: Int
        var reports = 0
        var firstHex: String?
    }
    private static var entries: [Entry] = []

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static func run() -> Never {
        let euid = geteuid()
        print("Bonk sensor probe v2 — \(euid == 0 ? "running as root" : "not root (uid \(euid))"), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("hardware: \(sysctlString("hw.model")) — \(sysctlString("machdep.cpu.brand_string"))")

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Match the whole vendor page — we want every SPU sensor, not just accel
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey as String: 0xFF00] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, device in
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "?"
            guard transport.contains("SPU") else { return }
            let usage     = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
            let product   = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
            let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
            let idx = SensorProbe.entries.count
            SensorProbe.entries.append(Entry(usage: usage, product: product, productID: productID))

            let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            if openResult != kIOReturnSuccess {
                print(String(format: "usage=%d open FAILED 0x%08x", usage, openResult))
            }
            IOHIDDeviceSetProperty(device, kIOHIDReportIntervalKey as CFString, 10_000 as CFNumber)
            let size = max(IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 22, 22)
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            buf.initialize(repeating: 0, count: size)
            // context carries the entry index (+1 so it's never a null pointer)
            let ctx = UnsafeMutableRawPointer(bitPattern: idx + 1)
            IOHIDDeviceRegisterInputReportCallback(device, buf, size, { ctx, _, _, _, _, report, length in
                guard let ctx else { return }
                let i = Int(bitPattern: ctx) - 1
                guard i >= 0 && i < SensorProbe.entries.count else { return }
                SensorProbe.entries[i].reports += 1
                if SensorProbe.entries[i].firstHex == nil {
                    SensorProbe.entries[i].firstHex = Data(bytes: report, count: Int(length))
                        .map { String(format: "%02x", $0) }.joined(separator: " ")
                }
            }, ctx)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let openRes = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openRes != kIOReturnSuccess {
            print(String(format: "manager open failed: 0x%08x", openRes))
        }

        print("listening to all SPU sensors for 5 seconds — knock and tilt the laptop…")
        RunLoop.main.run(until: Date().addingTimeInterval(5))

        var accelReports = 0
        var anyReports = 0
        print("--- results ---")
        for e in entries.sorted(by: { $0.usage < $1.usage }) {
            let rate = e.reports > 0 ? " (~\(e.reports / 5) Hz)" : ""
            print("usage=\(e.usage)  productID=\(e.productID)  reports=\(e.reports)\(rate)\(e.usage == 3 ? "  ← accelerometer" : "")")
            if e.usage == 3 { accelReports += e.reports }
            anyReports += e.reports
        }
        if let hex = entries.first(where: { $0.usage == 3 && $0.firstHex != nil })?.firstHex {
            print("accel first report: [\(hex)]")
        }
        if accelReports > 0 {
            print("VERDICT: accelerometer WORKS on this Mac.")
        } else if anyReports > 0 {
            print("VERDICT: other SPU sensors stream but the accelerometer is silent — accel-specific block on this model.")
        } else {
            print("VERDICT: no SPU sensor streams at all — this model doesn't deliver sensor data to apps.")
            if euid != 0 { print("(Optionally confirm with: sudo \"\(CommandLine.arguments[0])\" --probe)") }
        }
        exit(0)
    }
}
