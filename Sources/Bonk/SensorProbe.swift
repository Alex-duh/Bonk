import Foundation
import IOKit.hid

// Terminal diagnostic: `/Applications/Bonk.app/Contents/MacOS/Bonk --probe`
// Listens to the SPU accelerometer for 5 seconds and reports what happened.
// Exists because macOS 15 (Sequoia) restricts SPU sensor streaming to
// privileged processes — running the probe with and without sudo tells us
// exactly which privilege level a given Mac/OS needs.
enum SensorProbe {
    private static var reportCount = 0
    private static var loggedFirst = false

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
        print("Bonk sensor probe — \(euid == 0 ? "running as root" : "not root (uid \(euid))"), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("hardware: \(sysctlString("hw.model")) — \(sysctlString("machdep.cpu.brand_string"))")

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: 0xFF00,
            kIOHIDDeviceUsageKey     as String: 3,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, _, _, device in
            let product   = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "?"
            print("matched: '\(product)' transport=\(transport)")
            guard transport.contains("SPU") else { print("  → skipped (not the SPU sensor)"); return }
            let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            print(String(format: "  device open: 0x%08x %@", openResult, openResult == kIOReturnSuccess ? "(ok)" : "(FAILED)"))
            IOHIDDeviceSetProperty(device, kIOHIDReportIntervalKey as CFString, 10_000 as CFNumber)
            let size = max(IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 22, 22)
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            buf.initialize(repeating: 0, count: size)
            IOHIDDeviceRegisterInputReportCallback(device, buf, size, { _, _, _, _, _, report, length in
                SensorProbe.reportCount += 1
                if !SensorProbe.loggedFirst {
                    SensorProbe.loggedFirst = true
                    let hex = Data(bytes: report, count: Int(length))
                        .map { String(format: "%02x", $0) }.joined(separator: " ")
                    print("first report (\(length) bytes): [\(hex)]")
                }
            }, nil)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let openRes = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openRes != kIOReturnSuccess {
            print(String(format: "manager open failed: 0x%08x", openRes))
        }

        print("listening for 5 seconds — knock on the laptop a few times…")
        RunLoop.main.run(until: Date().addingTimeInterval(5))

        if reportCount > 0 {
            print("RESULT: \(reportCount) reports (~\(reportCount / 5) Hz) — the sensor WORKS at this privilege level.")
        } else {
            print("RESULT: no data at this privilege level.")
            if euid != 0 {
                print("Now try:  sudo \"\(CommandLine.arguments[0])\" --probe")
            }
        }
        exit(0)
    }
}
