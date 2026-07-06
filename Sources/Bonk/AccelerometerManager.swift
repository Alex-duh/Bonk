import Foundation
import IOKit.hid

// Apple Silicon MacBooks expose their MEMS IMU (Bosch BMI286) as an IOKit HID
// device — NOT through CoreMotion. The device appears in the IOKit registry as
// AppleSPUHIDDevice with vendor usage page 0xFF00, usage 3.
// Data arrives as 22-byte reports; x/y/z are int32 LE at byte offsets 6/10/14,
// scaled by 1/65536 to convert to g-force units.

private let kUsagePage: Int = 0xFF00
private let kUsage:     Int = 3
private let kEmaAlpha:  Double = 0.02  // slow-adapting baseline; ignores knock spikes

let kWaveformCapacity = 300  // 3 seconds at 100 Hz — shared with WaveformCanvas

typealias AccelCallback = (Double, Double, Double, Double) -> Void  // x, y, z, delta

class AccelerometerManager {
    static let shared = AccelerometerManager()

    private(set) var isAvailable = false
    private var hidManager: IOHIDManager?
    private var deviceBuffers: [(device: IOHIDDevice, buf: UnsafeMutablePointer<UInt8>)] = []
    private var userCallback: AccelCallback?

    // EMA baseline — adapts slowly so the knock spike doesn't pull the floor up
    private var emaBaseline: Double?

    // Waveform ring buffer — main thread only, polled by WaveformView at 30 fps
    private(set) var waveformSamples: [Double] = []
    private(set) var latestDelta: Double = 0

    // Calibration (noise floor — 3 s of rest samples)
    private(set) var isCalibrating = false
    private var calibrationSamples: [Double] = []
    var onCalibrationComplete: ((Double) -> Void)?

    // Tap calibration — user taps N times; threshold derived from their softest tap
    private(set) var isTapCalibrating = false
    private var tapPeaks: [Double] = []
    private var tapInSpike = false
    private var tapSpikePeak: Double = 0
    private var tapLastEnd: Date = .distantPast
    private var tapStart: Date = .distantPast
    private var tapTarget = 3
    private var onTapProgress: ((Int) -> Void)?
    private var onTapCalibrationComplete: ((Double) -> Void)?

    var onUnavailable: (() -> Void)?
    private var checkTimer: Timer?

    private init() {}

    func start(callback: @escaping AccelCallback) {
        userCallback = callback
        // NOTE: the SPU accelerometer (vendor usage page 0xFF00) is NOT gated by
        // Input Monitoring — confirmed empirically: it streams on a machine where
        // that permission was never granted. Don't add IOHIDRequestAccess here;
        // it only scares users with a keyboard-monitoring prompt.
        openHIDManager()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self, !self.isAvailable else { return }
            klog("accel: no HID device matched after 3 s (usagePage 0xFF00 usage 3) — sensor absent or not exposed on this Mac/OS")
            self.onUnavailable?()
        }
    }

    func stop() {
        checkTimer?.invalidate()
        let loop = CFRunLoopGetMain()!
        for entry in deviceBuffers {
            IOHIDDeviceUnscheduleFromRunLoop(entry.device, loop, CFRunLoopMode.commonModes.rawValue)
            entry.buf.deallocate()
        }
        deviceBuffers.removeAll()
        if let m = hidManager {
            IOHIDManagerUnscheduleFromRunLoop(m, loop, CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        hidManager = nil
    }

    // Collects 300 rest samples and calls completion with mean + 3σ threshold.
    func startCalibration(completion: @escaping (Double) -> Void) {
        calibrationSamples = []
        isCalibrating = true
        onCalibrationComplete = completion
    }

    // Tap-to-calibrate: waits for `taps` distinct taps above a small fixed floor,
    // then sets the threshold to half the softest tap's peak — so knocks at the
    // user's natural strength register comfortably. Clamped to a sane range.
    func startTapCalibration(taps: Int = 3,
                             progress: @escaping (Int) -> Void,
                             completion: @escaping (Double) -> Void) {
        tapTarget = taps
        tapPeaks = []
        tapInSpike = false
        tapSpikePeak = 0
        tapLastEnd = .distantPast
        tapStart = Date()
        onTapProgress = progress
        onTapCalibrationComplete = completion
        isTapCalibrating = true
    }

    func cancelTapCalibration() {
        isTapCalibrating = false
        onTapProgress = nil
        onTapCalibrationComplete = nil
    }

    // MARK: - IOKit setup

    private func openHIDManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kUsagePage,
            kIOHIDDeviceUsageKey     as String: kUsage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<AccelerometerManager>.fromOpaque(ctx).takeUnretainedValue().attach(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<AccelerometerManager>.fromOpaque(ctx).takeUnretainedValue().detach(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            klog(String(format: "accel: IOHIDManagerOpen failed 0x%08x (permission or driver issue)", result))
        }
        hidManager = manager
    }

    private func attach(_ device: IOHIDDevice) {
        guard !deviceBuffers.contains(where: { $0.device == device }) else { return }
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
        klog("accel: HID device attached: \(product)")
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 22)
        buf.initialize(repeating: 0, count: 22)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buf, 22, { ctx, _, _, _, _, report, length in
            guard let ctx, length >= 15 else { return }
            Unmanaged<AccelerometerManager>.fromOpaque(ctx).takeUnretainedValue()
                .parseReport(report, length: length)
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        deviceBuffers.append((device, buf))
    }

    private func detach(_ device: IOHIDDevice) {
        if let i = deviceBuffers.firstIndex(where: { $0.device == device }) {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            deviceBuffers[i].buf.deallocate()
            deviceBuffers.remove(at: i)
        }
    }

    // MARK: - Data parsing

    private var loggedFirstReport = false

    private func parseReport(_ report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        let data = Data(bytes: report, count: min(Int(length), 64))
        // One-time hex dump — if a Mac model uses a different report layout,
        // this line in ~/Library/Logs/Bonk.log is how we find out
        if !loggedFirstReport {
            loggedFirstReport = true
            let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
            klog("accel: first report length=\(length) data=[\(hex)]")
        }
        guard data.count >= 18 else { return }

        let x = Double(readInt32LE(data, offset: 6))  / 65536.0
        let y = Double(readInt32LE(data, offset: 10)) / 65536.0
        let z = Double(readInt32LE(data, offset: 14)) / 65536.0
        let mag = (x*x + y*y + z*z).squareRoot()

        if !isAvailable {
            isAvailable = true
            checkTimer?.invalidate()
        }

        // EMA baseline — alpha=0.02 means a 0.5g spike shifts baseline by only 0.01g
        if emaBaseline == nil { emaBaseline = mag }
        emaBaseline = kEmaAlpha * mag + (1 - kEmaAlpha) * emaBaseline!
        let delta = abs(mag - emaBaseline!)

        // Waveform ring buffer — most-recent sample always at the right end
        waveformSamples.append(delta)
        if waveformSamples.count > kWaveformCapacity { waveformSamples.removeFirst() }
        latestDelta = delta

        if isCalibrating {
            calibrationSamples.append(delta)
            if calibrationSamples.count >= kWaveformCapacity {
                isCalibrating = false
                let n = Double(calibrationSamples.count)
                let mean = calibrationSamples.reduce(0, +) / n
                let variance = calibrationSamples.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n
                let stddev = variance.squareRoot()
                onCalibrationComplete?(mean + 3.0 * stddev)
            }
        }

        if isTapCalibrating { feedTapCalibration(delta: delta) }

        userCallback?(x, y, z, delta)
    }

    // Detects distinct taps above a small fixed floor (independent of the user's
    // configured threshold, so calibration works even if the threshold is way off).
    private func feedTapCalibration(delta: Double) {
        let floor = 0.04            // g — low enough to catch soft taps, above idle noise
        let debounce = 0.25         // s — separates taps from sensor ringing

        // Safety timeout: an abandoned calibration (e.g. settings window closed
        // mid-flow) must not mute knock detection forever.
        if Date().timeIntervalSince(tapStart) > 30 {
            cancelTapCalibration()
            return
        }

        if delta >= floor {
            if !tapInSpike {
                tapInSpike = true
                tapSpikePeak = delta
            } else {
                tapSpikePeak = max(tapSpikePeak, delta)
            }
        } else if tapInSpike {
            tapInSpike = false
            let now = Date()
            guard now.timeIntervalSince(tapLastEnd) > debounce else { return }
            tapLastEnd = now
            tapPeaks.append(tapSpikePeak)
            onTapProgress?(tapPeaks.count)
            if tapPeaks.count >= tapTarget {
                isTapCalibrating = false
                // Half the softest tap: taps at natural strength clear it easily.
                let threshold = min(max((tapPeaks.min() ?? 0.3) * 0.5, 0.02), 0.8)
                onTapCalibrationComplete?(threshold)
                onTapProgress = nil
                onTapCalibrationComplete = nil
            }
        }
    }

    private func readInt32LE(_ data: Data, offset: Int) -> Int32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            Int32(littleEndian: $0.load(as: Int32.self))
        }
    }
}
