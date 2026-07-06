import AppKit
import Carbon.HIToolbox
import Darwin

private let logURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Logs/Bonk.log")

func klog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let fh = try? FileHandle(forWritingTo: logURL) {
                fh.seekToEndOfFile(); fh.write(data); try? fh.close()
            }
        } else {
            try? data.write(to: logURL)
        }
    }
    NSLog("[Bonk] %@", msg)
}

enum Commands {
    static let none            = "None"
    static let playPause       = "Play/Pause"
    static let nextTrack       = "Next Track"
    static let prevTrack       = "Previous Track"
    static let volumeUp        = "Volume Up"
    static let volumeDown      = "Volume Down"
    static let mute            = "Mute/Unmute"
    static let lockScreen      = "Lock Screen"
    static let sleep           = "Sleep Mac"
    static let screenshot      = "Screenshot"
    static let nextTab         = "Next Tab"
    static let prevTab         = "Previous Tab"
    static let nextDesktop     = "Next Desktop"
    static let prevDesktop     = "Previous Desktop"
    static let missionControl  = "Mission Control"
    static let appSwitcher     = "App Switcher"
    static let spotlight       = "Open Spotlight"
    static let finder          = "Open Finder"
    static let terminal        = "Open Terminal"
    static let closeWindow     = "Close Window"
    static let undo            = "Undo"
    static let redo            = "Redo"
    static let copy            = "Copy"
    static let paste           = "Paste"
    static let aiAccept        = "AI Accept (Press Enter)"
    static let keyboardShortcut = "Press Keyboard Shortcut…"
    static let runShortcut     = "Run Shortcuts Shortcut…"
    static let custom          = "Run Shell Command…"
    static let openApp         = "Open App…"

    // Old names persisted in UserDefaults before the rename
    static let legacyCustom    = "Run Custom Command"
    static let legacyOpenApp   = "Open App"

    static let all: [String] = [
        none, playPause, nextTrack, prevTrack, volumeUp, volumeDown, mute,
        lockScreen, sleep, screenshot, nextTab, prevTab,
        nextDesktop, prevDesktop, missionControl, appSwitcher,
        spotlight, finder, terminal, closeWindow,
        undo, redo, copy, paste,
        aiAccept, keyboardShortcut, runShortcut, custom, openApp,
    ]

    // Commands whose behaviour is configured by a text argument
    static func needsArg(_ cmd: String) -> Bool {
        [keyboardShortcut, runShortcut, custom, openApp].contains(cmd)
    }
}

enum CommandExecutor {

    static func execute(command: String, arg: String = "") {
        klog("execute: \(command) trusted=\(AXIsProcessTrusted())")
        switch command {
        case Commands.none:           break
        case Commands.playPause:      playPause()
        case Commands.nextTrack:      mediaKey(NX_KEYTYPE_NEXT)
        case Commands.prevTrack:      mediaKey(NX_KEYTYPE_PREVIOUS)
        case Commands.volumeUp:       mediaKey(NX_KEYTYPE_SOUND_UP)
        case Commands.volumeDown:     mediaKey(NX_KEYTYPE_SOUND_DOWN)
        case Commands.mute:           mediaKey(NX_KEYTYPE_MUTE)
        case Commands.lockScreen:     lockScreen()
        case Commands.sleep:          sleepMac()
        case Commands.screenshot:     screenshot()
        case Commands.nextTab:        cgKey(kVK_Tab,        flags: [.maskControl])
        case Commands.prevTab:        cgKey(kVK_Tab,        flags: [.maskControl, .maskShift])
        case Commands.nextDesktop:    cgKey(kVK_RightArrow, flags: [.maskControl])
        case Commands.prevDesktop:    cgKey(kVK_LeftArrow,  flags: [.maskControl])
        case Commands.missionControl: cgKey(kVK_F9,         flags: [])
        case Commands.appSwitcher:    cgKey(kVK_Tab,        flags: [.maskCommand])
        case Commands.spotlight:      cgKey(kVK_Space,      flags: [.maskCommand])
        case Commands.finder:         openApp(bundle: "com.apple.finder")
        case Commands.terminal:       openApp(bundle: "com.apple.Terminal")
        case Commands.closeWindow:    cgKey(kVK_ANSI_W,    flags: [.maskCommand])
        case Commands.undo:           cgKey(kVK_ANSI_Z,    flags: [.maskCommand])
        case Commands.redo:           cgKey(kVK_ANSI_Z,    flags: [.maskCommand, .maskShift])
        case Commands.copy:           cgKey(kVK_ANSI_C,    flags: [.maskCommand])
        case Commands.paste:          cgKey(kVK_ANSI_V,    flags: [.maskCommand])
        case Commands.aiAccept:       cgKey(kVK_Return, flags: [])
        case Commands.keyboardShortcut: pressShortcut(arg)
        case Commands.runShortcut:    runShortcutsShortcut(arg)
        case Commands.custom,
             Commands.legacyCustom:   runShell(arg)
        case Commands.openApp,
             Commands.legacyOpenApp:  openApp(name: arg)
        default:                      break
        }
    }

    // MARK: - Custom keyboard shortcut (spec like "cmd+shift+k")

    private static func pressShortcut(_ spec: String) {
        guard let combo = KeyCombo.parse(spec) else {
            klog("pressShortcut: could not parse '\(spec)' — expected e.g. cmd+shift+k")
            return
        }
        cgKey(combo.keyCode, flags: combo.flags)
    }

    // MARK: - Shortcuts.app (runs locally via the `shortcuts` CLI)

    private static func runShortcutsShortcut(_ name: String) {
        guard !name.isEmpty else { return }
        shellAsync("/usr/bin/shortcuts", args: ["run", name])
    }

    // Names of the user's Shortcuts, for the settings dropdown.
    static func listShortcuts() -> [String] {
        shell("/usr/bin/shortcuts", args: ["list"])
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - Play / Pause

    private static func playPause() {
        if AXIsProcessTrusted() {
            mediaKey(NX_KEYTYPE_PLAY)
        } else {
            // key code 100 = F8 / play-pause on Apple keyboards
            appleScriptKey(100)
        }
    }

    // MARK: - Media keys
    // CGEvent path needs Accessibility; falls back to AppleScript key codes which
    // only need Automation permission for System Events.

    private static func mediaKey(_ keyType: Int32) {
        if AXIsProcessTrusted() {
            func post(_ keyFlags: Int32) {
                let data1 = Int((keyType << 16) | (keyFlags << 8))
                let e = NSEvent.otherEvent(
                    with: .systemDefined,
                    location: .zero,
                    modifierFlags: NSEvent.ModifierFlags(rawValue: 0xa00),
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: 0, context: nil, subtype: 8,
                    data1: data1, data2: -1)
                e?.cgEvent?.post(tap: CGEventTapLocation.cghidEventTap)
            }
            post(0xa); post(0xb)
        } else {
            // F-key codes for Apple keyboard media functions
            let keyCodeMap: [Int32: Int] = [
                NX_KEYTYPE_PLAY:       100,   // F8
                NX_KEYTYPE_NEXT:       101,   // F9
                NX_KEYTYPE_PREVIOUS:   98,    // F7
                NX_KEYTYPE_SOUND_UP:   111,   // F12
                NX_KEYTYPE_SOUND_DOWN: 103,   // F11
                NX_KEYTYPE_MUTE:       74,    // F10
            ]
            if let code = keyCodeMap[keyType] {
                appleScriptKey(code)
            } else {
                klog("mediaKey: no AppleScript fallback for keyType \(keyType)")
            }
        }
    }

    // MARK: - Keyboard shortcuts (need Accessibility for CGEvent)

    private static func cgKey(_ keyCode: Int, flags: CGEventFlags) {
        guard AXIsProcessTrusted() else {
            klog("cgKey \(keyCode) skipped — Accessibility not granted; re-grant in System Settings → Privacy → Accessibility")
            return
        }
        let src = CGEventSource(stateID: .hidSystemState)
        let dn = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false)
        dn?.flags = flags; up?.flags = flags
        dn?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Lock / Sleep / Screenshot

    private static func lockScreen() {
        // Control+Command+Q triggers the real macOS lock screen (Touch ID / password required),
        // NOT ScreenSaverEngine which only shows a screensaver without locking.
        if AXIsProcessTrusted() {
            cgKey(kVK_ANSI_Q, flags: [.maskControl, .maskCommand])
        } else {
            var err: NSDictionary?
            NSAppleScript(source: """
                tell application "System Events"
                    keystroke "q" using {command down, control down}
                end tell
            """)?.executeAndReturnError(&err)
            if let err { klog("lockScreen AppleScript error: \(err)") }
        }
    }

    private static func sleepMac() {
        shell("/usr/bin/pmset", args: ["sleepnow"])
    }

    private static func screenshot() {
        if AXIsProcessTrusted() {
            cgKey(kVK_ANSI_3, flags: [.maskCommand, .maskShift])
        } else {
            let path = "\(NSHomeDirectory())/Desktop/screenshot-\(Int(Date().timeIntervalSince1970)).png"
            shell("/usr/sbin/screencapture", args: [path])
        }
    }

    // MARK: - Open apps (no permissions needed)

    private static func openApp(bundle bundleID: String) {
        klog("openApp bundle: \(bundleID)")
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            klog("openApp: bundle not found \(bundleID)"); return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private static func openApp(name: String) {
        guard !name.isEmpty else { return }
        klog("openApp name: \(name)")
        let ws = NSWorkspace.shared
        // Full path (from the Browse… picker)
        if name.hasPrefix("/"), FileManager.default.fileExists(atPath: name) {
            ws.openApplication(at: URL(fileURLWithPath: name), configuration: .init()); return
        }
        if let url = ws.urlForApplication(withBundleIdentifier: name) {
            ws.openApplication(at: url, configuration: .init()); return
        }
        for path in ["/Applications/\(name).app",
                     "/Applications/Utilities/\(name).app",
                     "\(NSHomeDirectory())/Applications/\(name).app"] {
            if FileManager.default.fileExists(atPath: path) {
                ws.openApplication(at: URL(fileURLWithPath: path), configuration: .init()); return
            }
        }
        klog("openApp: not found for '\(name)'")
    }

    // MARK: - AppleScript helper (Automation permission, no Accessibility needed)

    private static func appleScriptKey(_ keyCode: Int) {
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to key code \(keyCode)")?
            .executeAndReturnError(&err)
        if let err { klog("appleScriptKey \(keyCode) error: \(err)") }
    }

    // MARK: - Shell helpers

    private static func runShell(_ cmd: String) {
        guard !cmd.isEmpty else { return }
        shellAsync("/bin/zsh", args: ["-c", cmd])
    }

    // Non-blocking runner for user commands and Shortcuts — these can take
    // seconds and must not stall the main run loop (the sensor callback lives there).
    private static func shellAsync(_ exe: String, args: [String]) {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: exe)
        t.arguments = args
        let pipe = Pipe()
        t.standardError = pipe
        t.standardOutput = pipe
        t.terminationHandler = { proc in
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty || proc.terminationStatus != 0 {
                klog("\(exe) \(args.joined(separator: " ")) exit=\(proc.terminationStatus) output: \(trimmed)")
            }
        }
        do { try t.run() } catch { klog("shellAsync \(exe) failed: \(error)") }
    }

    @discardableResult
    private static func shell(_ exe: String, args: [String]) -> String {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: exe)
        t.arguments = args
        let pipe = Pipe()
        t.standardError = pipe
        t.standardOutput = pipe
        do {
            try t.run()
            t.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                klog("shell \(exe) output: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return out
        } catch {
            klog("shell \(exe) failed: \(error)")
            return ""
        }
    }
}

private let NX_KEYTYPE_SOUND_UP:   Int32 = 0
private let NX_KEYTYPE_SOUND_DOWN: Int32 = 1
private let NX_KEYTYPE_MUTE:       Int32 = 7
private let NX_KEYTYPE_PLAY:       Int32 = 16
private let NX_KEYTYPE_NEXT:       Int32 = 17
private let NX_KEYTYPE_PREVIOUS:   Int32 = 18
