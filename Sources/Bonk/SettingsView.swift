import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import ServiceManagement

// MARK: - BonkSettings

class BonkSettings: ObservableObject {
    static let shared = BonkSettings()

    @Published var singleKnockCommand: String {
        didSet { UserDefaults.standard.set(singleKnockCommand, forKey: "singleKnockCommand") }
    }
    @Published var doubleKnockCommand: String {
        didSet { UserDefaults.standard.set(doubleKnockCommand, forKey: "doubleKnockCommand") }
    }
    @Published var tripleKnockCommand: String {
        didSet { UserDefaults.standard.set(tripleKnockCommand, forKey: "tripleKnockCommand") }
    }
    @Published var quadKnockCommand: String {
        didSet { UserDefaults.standard.set(quadKnockCommand, forKey: "quadKnockCommand") }
    }
    @Published var singleKnockArg: String {
        didSet { UserDefaults.standard.set(singleKnockArg, forKey: "singleKnockArg") }
    }
    @Published var doubleKnockArg: String {
        didSet { UserDefaults.standard.set(doubleKnockArg, forKey: "doubleKnockArg") }
    }
    @Published var tripleKnockArg: String {
        didSet { UserDefaults.standard.set(tripleKnockArg, forKey: "tripleKnockArg") }
    }
    @Published var quadKnockArg: String {
        didSet { UserDefaults.standard.set(quadKnockArg, forKey: "quadKnockArg") }
    }
    // Sensitivity threshold in g (set manually or by calibration)
    @Published var thresholdG: Double {
        didSet { UserDefaults.standard.set(thresholdG, forKey: "thresholdG") }
    }
    // Time window to collect knocks for a sequence (ms)
    @Published var windowMs: Double {
        didSet { UserDefaults.standard.set(windowMs, forKey: "windowMs") }
    }
    // Dead-time after a command fires (ms)
    @Published var cooldownMs: Double {
        didSet { UserDefaults.standard.set(cooldownMs, forKey: "cooldownMs") }
    }
    // Maximum spike duration before discarding as sustained vibration (ms)
    @Published var maxSpikeDurationMs: Double {
        didSet { UserDefaults.standard.set(maxSpikeDurationMs, forKey: "maxSpikeDurationMs") }
    }
    // Test mode — knocks are detected, flashed, and logged, but no action fires
    @Published var testMode: Bool {
        didSet { UserDefaults.standard.set(testMode, forKey: "testMode") }
    }
    // Pause — stop listening for knocks entirely. Deliberately not persisted:
    // a fresh launch always starts detecting.
    @Published var isPaused = false
    // Per-app overrides, stored as JSON
    @Published var appRules: [AppRule] {
        didSet {
            if let data = try? JSONEncoder().encode(appRules) {
                UserDefaults.standard.set(data, forKey: "appRules")
            }
        }
    }

    private init() {
        let d = UserDefaults.standard
        singleKnockCommand  = d.string(forKey: "singleKnockCommand") ?? Commands.playPause
        doubleKnockCommand  = d.string(forKey: "doubleKnockCommand") ?? Commands.lockScreen
        tripleKnockCommand  = d.string(forKey: "tripleKnockCommand") ?? Commands.screenshot
        quadKnockCommand    = d.string(forKey: "quadKnockCommand")   ?? Commands.none
        singleKnockArg      = d.string(forKey: "singleKnockArg")     ?? ""
        doubleKnockArg      = d.string(forKey: "doubleKnockArg")     ?? ""
        tripleKnockArg      = d.string(forKey: "tripleKnockArg")     ?? ""
        quadKnockArg        = d.string(forKey: "quadKnockArg")       ?? ""
        thresholdG          = d.object(forKey: "thresholdG")          != nil ? d.double(forKey: "thresholdG")          : 0.30
        windowMs            = d.object(forKey: "windowMs")            != nil ? d.double(forKey: "windowMs")            : 450.0
        cooldownMs          = d.object(forKey: "cooldownMs")          != nil ? d.double(forKey: "cooldownMs")          : 1000.0
        maxSpikeDurationMs  = d.object(forKey: "maxSpikeDurationMs")  != nil ? d.double(forKey: "maxSpikeDurationMs")  : 120.0
        testMode            = d.bool(forKey: "testMode")
        if let data = d.data(forKey: "appRules"),
           let rules = try? JSONDecoder().decode([AppRule].self, from: data) {
            appRules = rules
        } else {
            appRules = []
        }
    }
}

// MARK: - KnockLog

struct KnockLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let label: String
    let peaks: [Double]
    let command: String
}

class KnockLog: ObservableObject {
    static let shared = KnockLog()
    @Published private(set) var entries: [KnockLogEntry] = []
    private init() {}

    func add(label: String, peaks: [Double], command: String) {
        let e = KnockLogEntry(timestamp: Date(), label: label, peaks: peaks, command: command)
        entries.insert(e, at: 0)
        if entries.count > 10 { entries.removeLast() }
    }

    func clear() { entries.removeAll() }
}

// MARK: - SettingsView

struct SettingsView: View {
    // Observed so the command pickers re-render when a selection changes —
    // hand-rolled Binding closures without observation leave the pickers
    // visually stuck on their last-rendered value.
    @ObservedObject private var settings = BonkSettings.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                Divider().padding(.vertical, 12)
                TestModeSection()
                Divider().padding(.vertical, 12)
                WaveformSection()
                Divider().padding(.vertical, 12)
                CalibrationSection()
                Divider().padding(.vertical, 12)
                commandSection
                Divider().padding(.vertical, 12)
                PerAppSection()
                Divider().padding(.vertical, 12)
                FineTuneSection()
                Divider().padding(.vertical, 12)
                AccessibilityStatusView()
                Divider().padding(.vertical, 12)
                KnockLogSection()
                Spacer(minLength: 16)
            }
            .padding(24)
        }
        .frame(width: 540)
    }

    private var headerSection: some View {
        Text("Bonk Settings")
            .font(.title2.bold())
    }

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Knock Commands")
                .fontWeight(.semibold)
            Text("Each pattern can run any action — built-ins, keyboard shortcuts, apps, shell commands, or Shortcuts. These are just the defaults.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
            KnockRow(label: "Single knock",
                     command: $settings.singleKnockCommand,
                     arg:     $settings.singleKnockArg)
            KnockRow(label: "Double knock",
                     command: $settings.doubleKnockCommand,
                     arg:     $settings.doubleKnockArg)
            KnockRow(label: "Triple knock",
                     command: $settings.tripleKnockCommand,
                     arg:     $settings.tripleKnockArg)
            KnockRow(label: "Quad knock",
                     command: $settings.quadKnockCommand,
                     arg:     $settings.quadKnockArg)
        }
    }
}

// MARK: - Test mode

struct TestModeSection: View {
    @ObservedObject private var settings = BonkSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledSwitch(
                title: "Pause detection",
                caption: "Stop listening for knocks entirely. Same as “Pause Detection” in the menu bar; resets on relaunch.",
                isOn: $settings.isPaused)
            LabeledSwitch(
                title: "Test mode",
                caption: "Knocks are detected, flashed in the menu bar, and logged below — but no action fires. Great for tuning.",
                isOn: $settings.testMode)
            LaunchAtLoginSwitch()
        }
    }
}

// Launch at login via SMAppService — the service itself is the source of
// truth, so nothing is stored in UserDefaults.
private struct LaunchAtLoginSwitch: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        LabeledSwitch(
            title: "Launch at login",
            caption: "Start Bonk automatically when you log in to your Mac.",
            isOn: Binding(
                get: { enabled },
                set: { wantOn in
                    do {
                        if wantOn { try SMAppService.mainApp.register() }
                        else      { try SMAppService.mainApp.unregister() }
                    } catch {
                        klog("launch at login toggle failed: \(error)")
                    }
                    enabled = SMAppService.mainApp.status == .enabled
                }))
    }
}

// Full-width row with the switch pinned to the trailing edge, so stacked
// toggles line up regardless of label length.
private struct LabeledSwitch: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

// MARK: - Waveform

struct WaveformSection: View {
    @State private var samples: [Double] = []
    @State private var latestDelta: Double = 0
    @State private var flashUntil: Date = .distantPast
    @State private var detectorStatus: String = ""
    @State private var detectorStatusTime: Date?

    private static let statusFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Live Waveform").fontWeight(.semibold)
                Spacer()
                Text(String(format: "%.4f g", latestDelta))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            WaveformCanvas(
                samples: samples,
                threshold: BonkSettings.shared.thresholdG,
                isFlashing: Date() < flashUntil
            )
            .frame(height: 120)
            HStack {
                Text("3 seconds")
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
                Text("now")
                    .font(.caption2).foregroundColor(.secondary)
            }
            // Why the last threshold crossing did / didn't count — live debugging aid
            HStack(spacing: 4) {
                Image(systemName: "waveform.path.ecg")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(detectorStatusTime.map { "[\(Self.statusFmt.string(from: $0))] \(detectorStatus)" }
                     ?? "Detector: \(detectorStatus)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(detectorStatus.hasPrefix("knock") || detectorStatus.hasPrefix("fired")
                                     ? .green : .secondary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .onReceive(Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()) { _ in
            samples = AccelerometerManager.shared.waveformSamples
            latestDelta = AccelerometerManager.shared.latestDelta
            detectorStatus = KnockDetector.shared.lastStatus
            detectorStatusTime = KnockDetector.shared.lastStatusTime
        }
        .onReceive(NotificationCenter.default.publisher(for: .bonkKnockDetected)) { _ in
            flashUntil = Date().addingTimeInterval(0.2)
        }
    }
}

struct WaveformCanvas: View {
    let samples: [Double]
    let threshold: Double
    let isFlashing: Bool

    var body: some View {
        Canvas { context, size in
            let midY  = size.height / 2
            // Scale so the threshold sits at ~30% from centre; expands if actual peaks exceed it
            let maxVal = max(threshold * 3.5, (samples.max() ?? 0) * 1.1, 0.25)

            // Background
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color.black.opacity(0.88))
            )

            // Baseline centre
            var cl = Path()
            cl.move(to: CGPoint(x: 0, y: midY))
            cl.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(cl, with: .color(.gray.opacity(0.35)), lineWidth: 1)

            // Dashed threshold line
            let threshY = midY - CGFloat(threshold / maxVal) * midY
            var tl = Path()
            tl.move(to: CGPoint(x: 0, y: threshY))
            tl.addLine(to: CGPoint(x: size.width, y: threshY))
            context.stroke(tl, with: .color(.red.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))

            // Waveform — right-aligned so newest sample is always at the right edge
            guard samples.count > 1 else { return }
            let cap  = CGFloat(kWaveformCapacity)
            let startX = CGFloat(kWaveformCapacity - samples.count)  // left pad before buffer fills

            var wave = Path()
            for (i, s) in samples.enumerated() {
                let x = (startX + CGFloat(i)) / cap * size.width
                let y = midY - CGFloat(min(s / maxVal, 1.0)) * midY
                if i == 0 { wave.move(to: CGPoint(x: x, y: y)) }
                else       { wave.addLine(to: CGPoint(x: x, y: y)) }
            }

            let lineColor: Color = isFlashing ? .green : Color.green.opacity(0.65)
            context.stroke(wave, with: .color(lineColor), lineWidth: 1.5)

            // Bright flash overlay on the most-recent ~300ms of data
            if isFlashing && samples.count > 1 {
                let flashCount = min(30, samples.count)  // ~300ms at 100Hz
                let flashStart = samples.count - flashCount
                var flash = Path()
                for i in flashStart..<samples.count {
                    let x = (startX + CGFloat(i)) / cap * size.width
                    let y = midY - CGFloat(min(samples[i] / maxVal, 1.0)) * midY
                    if i == flashStart { flash.move(to: CGPoint(x: x, y: y)) }
                    else               { flash.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(flash, with: .color(.green), lineWidth: 3)
            }
        }
        .background(Color.black.opacity(0.88))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Calibration

private enum CalibState {
    case idle
    case running(countdown: Int)
    case tapWaiting(got: Int)
    case done(threshold: Double)
}

struct CalibrationSection: View {
    @ObservedObject private var settings = BonkSettings.shared
    @State private var state: CalibState = .idle
    @State private var calibStart: Date = .distantPast

    private let tapTarget = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calibration").fontWeight(.semibold)
            Text("Knock to Calibrate: knock 3× at your natural strength and the threshold is set to half your softest knock. Noise Floor: keep the laptop still for 3 s and the threshold is set just above ambient vibration.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                switch state {
                case .idle:
                    Button("Knock to Calibrate (3×)") { beginTapCalibration() }
                        .buttonStyle(.borderedProminent)
                    Button("Noise Floor") { beginCalibration() }

                case .running(let countdown):
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 20, height: 20)
                    Text(countdown > 0 ? "Keep still… \(countdown)" : "Processing…")
                        .foregroundColor(.orange)
                        .monospacedDigit()

                case .tapWaiting(let got):
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 20, height: 20)
                    Text("Knock \(tapTarget - got) more time\(tapTarget - got == 1 ? "" : "s")…")
                        .foregroundColor(.orange)
                        .monospacedDigit()
                    Button("Cancel") {
                        AccelerometerManager.shared.cancelTapCalibration()
                        state = .idle
                    }
                    .font(.caption)

                case .done(let t):
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(String(format: "Done — threshold set to %.4f g", t))
                        .foregroundColor(.green)
                        .font(.callout)
                    Button("Recalibrate") { state = .idle }
                        .font(.caption)
                }
                Spacer()
            }
            .frame(height: 28)
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            if case .running = state {
                let elapsed = Int(Date().timeIntervalSince(calibStart))
                let remaining = max(0, 3 - elapsed)
                state = .running(countdown: remaining)
            }
            // Tap calibration auto-times-out after 30 s — reflect that in the UI
            if case .tapWaiting = state, !AccelerometerManager.shared.isTapCalibrating {
                state = .idle
            }
        }
        .onDisappear {
            // Never leave detection muted because the window closed mid-calibration
            if case .tapWaiting = state {
                AccelerometerManager.shared.cancelTapCalibration()
                state = .idle
            }
        }
    }

    private func beginCalibration() {
        calibStart = Date()
        state = .running(countdown: 3)
        AccelerometerManager.shared.startCalibration { threshold in
            DispatchQueue.main.async {
                settings.thresholdG = threshold
                state = .done(threshold: threshold)
            }
        }
    }

    private func beginTapCalibration() {
        state = .tapWaiting(got: 0)
        AccelerometerManager.shared.startTapCalibration(taps: tapTarget) { got in
            DispatchQueue.main.async {
                if got < tapTarget { state = .tapWaiting(got: got) }
            }
        } completion: { threshold in
            DispatchQueue.main.async {
                settings.thresholdG = threshold
                state = .done(threshold: threshold)
            }
        }
    }
}

// MARK: - Fine-tune controls

struct FineTuneSection: View {
    @ObservedObject private var settings = BonkSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Detection Tuning").fontWeight(.semibold)

            LabeledSlider(
                label: "Sensitivity threshold",
                value: $settings.thresholdG,
                range: 0.01...0.80,
                step: 0.005,
                format: { String(format: "%.3f g", $0) },
                caption: "How hard you must knock — the dashed red line on the waveform. Lower catches lighter knocks but risks false triggers; higher needs firmer knocks. Calibration sets this for you."
            )

            LabeledSlider(
                label: "Knock window",
                value: $settings.windowMs,
                range: 150...800,
                step: 10,
                format: { String(format: "%.0f ms", $0) },
                caption: "How long Bonk waits for another knock before acting. Longer makes double/triple knocks easier to land; shorter makes single knocks respond faster."
            )

            LabeledSlider(
                label: "Cooldown after action",
                value: $settings.cooldownMs,
                range: 200...3000,
                step: 50,
                format: { String(format: "%.0f ms", $0) },
                caption: "Quiet period after an action fires, so one knocking session can't trigger twice (the chassis keeps vibrating briefly)."
            )

            LabeledSlider(
                label: "Max knock duration",
                value: $settings.maxSpikeDurationMs,
                range: 40...400,
                step: 10,
                format: { String(format: "%.0f ms", $0) },
                caption: "Real knocks are sharp — anything vibrating longer than this (fan spin-up, desk wobble, setting the laptop down) is ignored. Raise it only if firm knocks show as \"vibration\" in the detector status."
            )
        }
    }
}

// MARK: - Accessibility status

struct AccessibilityStatusView: View {
    @State private var trusted = AXIsProcessTrusted()
    private let refreshTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: trusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .foregroundColor(trusted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(trusted ? "Accessibility: Granted" : "Accessibility: Not granted")
                    .fontWeight(.medium)
                    .foregroundColor(trusted ? .primary : .red)
                if !trusted {
                    Text("Keyboard shortcuts (tabs, desktops, spotlight…) won't fire. Re-grant after every build.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if !trusted {
                Button("Open Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                    )
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(trusted ? Color.green.opacity(0.08) : Color.red.opacity(0.08))
        .cornerRadius(8)
        .onReceive(refreshTimer) { _ in trusted = AXIsProcessTrusted() }
    }
}

// MARK: - Knock log

struct KnockLogSection: View {
    @ObservedObject private var log = KnockLog.shared

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Knock Log").fontWeight(.semibold)
                Spacer()
                if !log.entries.isEmpty {
                    Button("Clear") { log.clear() }
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if log.entries.isEmpty {
                Text("No knocks detected yet — try knocking!")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(log.entries) { entry in
                        let peaksStr = entry.peaks
                            .map { String(format: "%.3fg", $0) }
                            .joined(separator: ", ")
                        Text("[\(Self.timeFmt.string(from: entry.timestamp))]  \(entry.label)  •  peak: \(peaksStr)  •  \(entry.command)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(8)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2), lineWidth: 1))
            }
        }
    }
}

// MARK: - KnockRow

private struct KnockRow: View {
    let label: String
    @Binding var command: String
    @Binding var arg: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .frame(width: 110, alignment: .leading)
                Picker("", selection: $command) {
                    ForEach(Commands.all, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            if Commands.needsArg(command) {
                ArgField(command: command, arg: $arg)
                    .padding(.leading, 114)
            }
        }
    }
}

// MARK: - ArgField — argument editor matched to the selected command

struct ArgField: View {
    let command: String
    @Binding var arg: String
    @State private var shortcutNames: [String] = []

    var body: some View {
        switch command {
        case Commands.keyboardShortcut:
            HStack(spacing: 6) {
                TextField("e.g. cmd+shift+k", text: $arg)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: KeyCombo.isValid(arg) ? "checkmark.circle.fill" : "questionmark.circle")
                    .foregroundColor(KeyCombo.isValid(arg) ? .green : (arg.isEmpty ? .secondary : .orange))
                    .help("Modifiers: cmd, shift, opt, ctrl, fn — plus one key: a–z, 0–9, f1–f20, enter, space, tab, esc, arrows, delete…")
            }

        case Commands.runShortcut:
            HStack(spacing: 6) {
                TextField("Shortcut name (Shortcuts.app)", text: $arg)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    if shortcutNames.isEmpty {
                        Text("No shortcuts found")
                    } else {
                        ForEach(shortcutNames, id: \.self) { name in
                            Button(name) { arg = name }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Pick one of your Shortcuts")
            }
            .onAppear {
                guard shortcutNames.isEmpty else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let names = CommandExecutor.listShortcuts()
                    DispatchQueue.main.async { shortcutNames = names }
                }
            }

        case Commands.custom, Commands.legacyCustom:
            TextField("Shell command (runs in zsh)", text: $arg)
                .textFieldStyle(.roundedBorder)

        case Commands.openApp, Commands.legacyOpenApp:
            HStack(spacing: 6) {
                TextField("App name (e.g. Safari) or path", text: $arg)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    panel.allowedContentTypes = [.application]
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        arg = url.path
                    }
                }
                .font(.caption)
            }

        default:
            EmptyView()
        }
    }
}

// MARK: - Per-app overrides

struct PerAppSection: View {
    @ObservedObject private var settings = BonkSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Per-App Overrides").fontWeight(.semibold)
                Spacer()
                Button("Add Rule") {
                    settings.appRules.append(
                        AppRule(bundleID: "", appName: "", pattern: 2,
                                command: Commands.aiAccept, arg: ""))
                }
                .font(.caption)
            }
            Text("When one of these apps is frontmost, its rule replaces the global mapping for that knock pattern. Try: double knock → AI Accept in your terminal or editor.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.appRules.isEmpty {
                Text("No overrides yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach($settings.appRules) { $rule in
                    AppRuleRow(rule: $rule) {
                        settings.appRules.removeAll { $0.id == rule.id }
                    }
                }
            }
        }
    }
}

private struct AppRuleRow: View {
    @Binding var rule: AppRule
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                appPicker
                    .frame(width: 140)
                Picker("", selection: $rule.pattern) {
                    ForEach([1, 2, 3, 4], id: \.self) {
                        Text(AppRule.patternLabels[$0] ?? "\($0)").tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 80)
                Picker("", selection: $rule.command) {
                    ForEach(Commands.all, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete rule")
            }
            if Commands.needsArg(rule.command) {
                ArgField(command: rule.command, arg: $rule.arg)
                    .padding(.leading, 146)
            }
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2), lineWidth: 1))
    }

    private var runningApps: [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let b = app.bundleIdentifier, let n = app.localizedName else { return nil }
                return (name: n, bundleID: b)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var appPicker: some View {
        Menu {
            ForEach(runningApps, id: \.bundleID) { app in
                Button(app.name) {
                    rule.bundleID = app.bundleID
                    rule.appName = app.name
                }
            }
            Divider()
            Button("Browse…") { browseForApp() }
        } label: {
            Text(rule.appName.isEmpty ? "Choose app…" : rule.appName)
                .foregroundColor(rule.appName.isEmpty ? .secondary : .primary)
                .lineLimit(1)
        }
    }

    private func browseForApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        rule.bundleID = bundleID
        rule.appName = url.deletingPathExtension().lastPathComponent
    }
}

// MARK: - LabeledSlider helper

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).frame(width: 160, alignment: .leading)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Slider(value: $value, in: range, step: step)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
