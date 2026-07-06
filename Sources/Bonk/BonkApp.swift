import AppKit
import SwiftUI
import Combine

extension Notification.Name {
    static let bonkKnockDetected = Notification.Name("BonkKnockDetected")
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    func menuWillOpen(_ menu: NSMenu) {
        menu.item(withTag: 3)?.state = BonkSettings.shared.testMode ? .on : .off
    }

    private var statusItem: NSStatusItem!
    private var settingsWindowController: NSWindowController?
    private var cancellables = Set<AnyCancellable>()
    // Set by setErrorState — accel.isAvailable is false at launch until the
    // sensor attaches, so it can't be used to pick the icon directly.
    private var sensorFailed = false

    private let accel    = AccelerometerManager.shared
    private let detector = KnockDetector.shared

    // Icon set: bare fist when idle (slashed variant when paused); fist with
    // 1/2/3 impact arcs flashed when a knock pattern is detected.
    private lazy var baseIcon:   NSImage? = makeTemplateIcon("idle_fist", slashed: false)
    private lazy var pausedIcon: NSImage? = makeTemplateIcon("idle_fist", slashed: true)
    private lazy var knockIcons: [Int: NSImage] = {
        var icons: [Int: NSImage] = [:]
        // four_knock.pdf is optional — quad falls back to the triple-arc icon
        for (count, name) in [1: "one_knock", 2: "two_knock", 3: "three_knock", 4: "four_knock"] {
            if let img = makeTemplateIcon(name, slashed: false) { icons[count] = img }
        }
        if icons[4] == nil { icons[4] = icons[3] }
        return icons
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Prompt for Accessibility — required for CGEvent keyboard shortcuts.
        // NOTE: every rebuild invalidates the app signature and resets this permission.
        // After building, re-grant in System Settings → Privacy & Security → Accessibility.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        buildStatusItem()

        // Pause can be toggled from the menu bar or the settings window —
        // this single subscriber keeps the icon and menu titles in sync.
        BonkSettings.shared.$isPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paused in self?.applyPauseState(paused) }
            .store(in: &cancellables)

        detector.onKnock = { [weak self] count, peaks in
            guard let self else { return }
            // Flash the impact-arc icon for the knock count, then restore
            if let icon = self.knockIcons[min(count, 4)] {
                self.statusItem.button?.image = icon
                self.statusItem.button?.title = ""
            } else {
                self.statusItem.button?.image = nil
                self.statusItem.button?.title = ["1️⃣", "2️⃣", "3️⃣", "4️⃣"][min(count, 4) - 1]
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.refreshIcon()
            }
            NotificationCenter.default.post(name: .bonkKnockDetected, object: nil)
            self.handleKnock(count: count, peaks: peaks)
        }

        accel.onUnavailable = { [weak self] in
            DispatchQueue.main.async { self?.setErrorState() }
        }

        accel.start { [weak self] x, y, z, delta in
            guard let self, !BonkSettings.shared.isPaused else { return }
            // Don't fire actions while a calibration is collecting samples
            guard !self.accel.isCalibrating, !self.accel.isTapCalibrating else { return }
            self.detector.feed(x: x, y: y, z: z, delta: delta)
        }
    }

    // MARK: - Menu bar icon

    // Rasterizes a Packaging/*.pdf icon (bundled into Resources) and converts
    // luminance → alpha, because template images render from the ALPHA channel:
    // the PDFs' opaque white background would otherwise draw as a solid square.
    // `slashed` overlays a diagonal line for the paused state.
    private func makeTemplateIcon(_ resource: String, slashed: Bool) -> NSImage? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "pdf"),
              let source = NSImage(contentsOf: url) else { return nil }
        let w = 40, h = 40   // rendered at 2× for a 20 pt menu bar slot
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        if slashed {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 3, y: 3))
            path.line(to: NSPoint(x: Double(w) - 3, y: Double(h) - 3))
            path.lineWidth = 3.5
            path.lineCapStyle = .round
            NSColor.black.setStroke()
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        for y in 0..<h {
            for x in 0..<w {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                rep.setColor(NSColor(calibratedRed: 0, green: 0, blue: 0,
                                     alpha: c.alphaComponent * (1 - lum)), atX: x, y: y)
            }
        }
        let img = NSImage(size: NSSize(width: 20, height: 20))
        img.addRepresentation(rep)
        img.isTemplate = true   // adapts to menu bar theme like other apps
        return img
    }

    // Single source of truth for the idle icon; falls back to the fist emoji
    // if the icon asset is missing from the bundle.
    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let paused = BonkSettings.shared.isPaused
        if baseIcon != nil {
            button.imagePosition = .imageLeft
            button.image = paused ? pausedIcon : baseIcon
            button.title = sensorFailed && !paused ? "⚠️" : ""
        } else {
            button.image = nil
            button.title = sensorFailed && !paused ? "✊⚠️" : (paused ? "✊💤" : "✊")
        }
    }

    // MARK: - Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Bonk"
        refreshIcon()

        let menu = NSMenu()
        let statusLabel = NSMenuItem(title: "Bonk — Active", action: nil, keyEquivalent: "")
        statusLabel.isEnabled = false
        statusLabel.tag = 1
        menu.addItem(statusLabel)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        let pauseItem = NSMenuItem(title: "Pause Detection", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.tag = 2
        menu.addItem(pauseItem)
        let testItem = NSMenuItem(title: "Test Mode (Don't Fire Actions)", action: #selector(toggleTestMode), keyEquivalent: "")
        testItem.tag = 3
        testItem.state = BonkSettings.shared.testMode ? .on : .off
        menu.addItem(testItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Bonk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Knock handling

    private func handleKnock(count: Int, peaks: [Double]) {
        let settings = BonkSettings.shared
        var (cmd, arg): (String, String) = {
            switch count {
            case 1: return (settings.singleKnockCommand, settings.singleKnockArg)
            case 2: return (settings.doubleKnockCommand, settings.doubleKnockArg)
            case 3: return (settings.tripleKnockCommand, settings.tripleKnockArg)
            case 4: return (settings.quadKnockCommand, settings.quadKnockArg)
            default: return (Commands.none, "")
            }
        }()
        // Per-app override for the frontmost app wins over the global mapping
        var suffix = ""
        if let rule = settings.appRules.match(count: count,
                                              frontmost: NSWorkspace.shared.frontmostApplication) {
            cmd = rule.command
            arg = rule.arg
            suffix = "  [\(rule.appName)]"
        }
        let label = ["Single knock", "Double knock", "Triple knock", "Quad knock"][min(count, 4) - 1]
        if settings.testMode {
            KnockLog.shared.add(label: label, peaks: peaks, command: "TEST — would run: \(cmd)\(suffix)")
            return
        }
        KnockLog.shared.add(label: label, peaks: peaks, command: cmd + suffix)
        CommandExecutor.execute(command: cmd, arg: arg)
    }

    // MARK: - Error state

    private func setErrorState() {
        sensorFailed = true
        refreshIcon()
        statusItem.menu?.item(withTag: 1)?.title = "Bonk — No Sensor"
        let alert = NSAlert()
        alert.messageText = "Accelerometer Not Available"
        alert.informativeText = "The accelerometer HID device was not found or access was denied.\n\nTo fix this:\n1. Open System Settings → Privacy & Security → Input Monitoring\n2. Add Bonk.app and toggle it ON\n3. Quit and rerun Bonk\n\nBonk requires an Apple Silicon MacBook (M1 or later)."
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Menu actions

    @objc private func togglePause(_ sender: NSMenuItem) {
        BonkSettings.shared.isPaused.toggle()   // UI updates via the $isPaused subscriber
    }

    private func applyPauseState(_ paused: Bool) {
        refreshIcon()
        if paused {
            statusItem.menu?.item(withTag: 1)?.title = "Bonk — Paused"
            statusItem.menu?.item(withTag: 2)?.title = "Resume Detection"
        } else {
            statusItem.menu?.item(withTag: 1)?.title = sensorFailed ? "Bonk — No Sensor" : "Bonk — Active"
            statusItem.menu?.item(withTag: 2)?.title = "Pause Detection"
        }
    }

    @objc private func toggleTestMode(_ sender: NSMenuItem) {
        BonkSettings.shared.testMode.toggle()
        sender.state = BonkSettings.shared.testMode ? .on : .off
    }

    @objc private func openSettings(_ sender: Any?) {
        if let wc = settingsWindowController {
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView()
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Bonk Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 540, height: 760))
        window.minSize = NSSize(width: 520, height: 600)
        window.center()
        window.isReleasedWhenClosed = false
        let wc = NSWindowController(window: window)
        settingsWindowController = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
