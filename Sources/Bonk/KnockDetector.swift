import Foundation
import AppKit

private let kDebounce:       Double = 0.08   // 80 ms — reject sensor ringing between knocks
private let kTypingSuppress: Double = 0.80   // 800 ms — ignore spikes right after a keypress

class KnockDetector {
    static let shared = KnockDetector()

    // count = 1/2/3; peaks = peak delta g-value per individual knock in the sequence
    var onKnock: ((Int, [Double]) -> Void)?

    // Diagnostics — why the last threshold crossing was or wasn't a knock.
    // Polled by the settings window; updated only on decisions, never per-sample.
    private(set) var lastStatus = "no threshold crossings yet"
    private(set) var lastStatusTime: Date?

    private func status(_ s: String) {
        lastStatus = s
        lastStatusTime = Date()
    }

    // Spike state — tracks one above-threshold excursion
    private var inSpike = false
    private var spikeStartTime: Date = .distantPast
    private var spikePeak: Double = 0
    // Set when a spike exceeds maxSpikeDurationMs (sustained vibration).
    // Suppresses re-triggering until the signal drops below threshold again,
    // so the tail end of a long vibration can't register as a knock.
    private var suppressUntilQuiet = false

    // Sequence accumulation
    private var knockPeaks: [Double] = []
    private var lastKnockEndTime: Date = .distantPast
    private var lastFireTime:     Date = .distantPast
    private var lastKeyTime:      Date = .distantPast
    private var windowTimer:      Timer?

    private var keyMonitor: Any?

    private init() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.lastKeyTime = Date()
        }
    }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }

    // Called at ~100 Hz on the main thread from AccelerometerManager callback.
    //
    // NOTE: at 100 Hz a sharp knock is often above threshold for a SINGLE sample
    // (~10 ms). There is deliberately no minimum-duration filter — one used to
    // exist (15 ms) and it silently rejected almost every real knock. Sharp and
    // short means knock; only sustained (> maxSpikeDurationMs) means vibration.
    func feed(x: Double, y: Double, z: Double, delta: Double) {
        let settings = BonkSettings.shared
        let threshold = settings.thresholdG
        let now = Date()

        if now.timeIntervalSince(lastKeyTime) < kTypingSuppress {
            if delta >= threshold { status("crossed threshold — ignored (0.8 s typing pause after any keypress)") }
            return
        }
        if now.timeIntervalSince(lastFireTime) < settings.cooldownMs / 1000.0 {
            if delta >= threshold { status("crossed threshold — ignored (cooldown after last action)") }
            return
        }

        if delta >= threshold {
            if suppressUntilQuiet { return }
            if !inSpike {
                inSpike = true
                spikeStartTime = now
                spikePeak = delta
            } else {
                spikePeak = max(spikePeak, delta)
                // Sustained vibration (e.g. fan spin-up, desk wobble) — abandon spike
                if now.timeIntervalSince(spikeStartTime) * 1000.0 > settings.maxSpikeDurationMs {
                    inSpike = false
                    suppressUntilQuiet = true
                    status("ignored — vibration longer than \(Int(settings.maxSpikeDurationMs)) ms (not a knock)")
                }
            }
        } else if suppressUntilQuiet {
            suppressUntilQuiet = false
        } else if inSpike {
            inSpike = false
            // Debounce: ignore re-triggers from sensor ringing
            if now.timeIntervalSince(lastKnockEndTime) > kDebounce {
                registerKnock(peak: spikePeak, at: now)
                status(String(format: "knock ✓ %.2f g (%d in window)", spikePeak, knockPeaks.count))
            } else {
                status("ignored — ringing right after previous knock")
            }
        }
    }

    // MARK: - Private

    private func registerKnock(peak: Double, at now: Date) {
        lastKnockEndTime = now
        knockPeaks.append(peak)
        windowTimer?.invalidate()
        let window = BonkSettings.shared.windowMs / 1000.0
        windowTimer = Timer.scheduledTimer(withTimeInterval: window, repeats: false) { [weak self] _ in
            self?.fireSequence()
        }
    }

    private func fireSequence() {
        let peaks = knockPeaks
        knockPeaks = []
        let count = peaks.count
        guard count >= 1 && count <= 4 else {
            status("ignored — \(count) knocks in one window (max 4)")
            return
        }
        lastFireTime = Date()
        let name = ["single", "double", "triple", "quad"][count - 1]
        status("fired: \(name) knock")
        onKnock?(count, peaks)
    }
}
