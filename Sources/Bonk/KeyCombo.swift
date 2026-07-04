import Carbon.HIToolbox
import CoreGraphics

// Parses a human-readable shortcut spec like "cmd+shift+k" or "ctrl+opt+right"
// into a virtual key code + modifier flags for CGEvent posting.
struct KeyCombo {
    let keyCode: Int
    let flags: CGEventFlags

    static func parse(_ spec: String) -> KeyCombo? {
        let parts = spec.lowercased()
            .split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var flags: CGEventFlags = []
        var key: String?
        for part in parts {
            switch part {
            case "cmd", "command", "⌘":      flags.insert(.maskCommand)
            case "shift", "⇧":               flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃":     flags.insert(.maskControl)
            case "fn":                        flags.insert(.maskSecondaryFn)
            default:
                guard key == nil else { return nil }  // two non-modifier keys
                key = part
            }
        }
        guard let key, let code = keyCodes[key] else { return nil }
        return KeyCombo(keyCode: code, flags: flags)
    }

    static func isValid(_ spec: String) -> Bool { parse(spec) != nil }

    private static let keyCodes: [String: Int] = {
        let m: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5,
            "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10,
            "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14,
            "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18,
            "f19": kVK_F19, "f20": kVK_F20,
            "space": kVK_Space, "spacebar": kVK_Space,
            "enter": kVK_Return, "return": kVK_Return,
            "tab": kVK_Tab,
            "esc": kVK_Escape, "escape": kVK_Escape,
            "delete": kVK_Delete, "backspace": kVK_Delete,
            "forwarddelete": kVK_ForwardDelete,
            "up": kVK_UpArrow, "down": kVK_DownArrow,
            "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "home": kVK_Home, "end": kVK_End,
            "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "-": kVK_ANSI_Minus, "minus": kVK_ANSI_Minus,
            "=": kVK_ANSI_Equal, "equals": kVK_ANSI_Equal,
            "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote,
            ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash,
            "`": kVK_ANSI_Grave,
        ]
        return m
    }()
}
