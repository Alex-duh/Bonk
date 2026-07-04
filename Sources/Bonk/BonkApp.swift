import AppKit
import SwiftUI

extension Notification.Name {
    static let bonkKnockDetected = Notification.Name("BonkKnockDetected")
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    func menuWillOpen(_ menu: NSMenu) {
        menu.item(withTag: 3)?.state = BonkSettings.shared.testMode ? .on : .off
    }

    private var statusItem: NSStatusItem!
    private var settingsWindowController: NSWindowController?
    private var isPaused = false

    private let accel    = AccelerometerManager.shared
    private let detector = KnockDetector.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Prompt for Accessibility — required for CGEvent keyboard shortcuts.
        // NOTE: every rebuild invalidates the app signature and resets this permission.
        // After building, re-grant in System Settings → Privacy & Security → Accessibility.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        buildStatusItem()

        detector.onKnock = { [weak self] count, peaks in
            guard let self else { return }
            let flash = count == 1 ? "1️⃣" : count == 2 ? "2️⃣" : "3️⃣"
            self.statusItem.button?.title = flash
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.statusItem.button?.title = self.isPaused ? "✊💤" : "✊"
            }
            NotificationCenter.default.post(name: .bonkKnockDetected, object: nil)
            self.handleKnock(count: count, peaks: peaks)
        }

        accel.onUnavailable = { [weak self] in
            DispatchQueue.main.async { self?.setErrorState() }
        }

        accel.start { [weak self] x, y, z, delta in
            guard let self, !self.isPaused else { return }
            // Don't fire actions while a calibration is collecting samples
            guard !self.accel.isCalibrating, !self.accel.isTapCalibrating else { return }
            self.detector.feed(x: x, y: y, z: z, delta: delta)
        }
    }

    // MARK: - Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✊"
        statusItem.button?.toolTip = "Bonk"

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
        let label = count == 1 ? "Single knock" : count == 2 ? "Double knock" : "Triple knock"
        if settings.testMode {
            KnockLog.shared.add(label: label, peaks: peaks, command: "TEST — would run: \(cmd)\(suffix)")
            return
        }
        KnockLog.shared.add(label: label, peaks: peaks, command: cmd + suffix)
        CommandExecutor.execute(command: cmd, arg: arg)
    }

    // MARK: - Error state

    private func setErrorState() {
        statusItem.button?.title = "✊⚠️"
        statusItem.menu?.item(withTag: 1)?.title = "Bonk — No Sensor"
        let alert = NSAlert()
        alert.messageText = "Accelerometer Not Available"
        alert.informativeText = "The accelerometer HID device was not found or access was denied.\n\nTo fix this:\n1. Open System Settings → Privacy & Security → Input Monitoring\n2. Add Bonk.app and toggle it ON\n3. Quit and rerun Bonk\n\nBonk requires an Apple Silicon MacBook (M1 or later)."
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Menu actions

    @objc private func togglePause(_ sender: NSMenuItem) {
        isPaused.toggle()
        if isPaused {
            sender.title = "Resume Detection"
            statusItem.button?.title = "✊💤"
            statusItem.menu?.item(withTag: 1)?.title = "Bonk — Paused"
        } else {
            sender.title = "Pause Detection"
            statusItem.button?.title = accel.isAvailable ? "✊" : "✊⚠️"
            statusItem.menu?.item(withTag: 1)?.title = "Bonk — Active"
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
