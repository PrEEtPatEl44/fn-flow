import CoreGraphics

/// A global push-to-talk shortcut: either a lone modifier key (e.g. Right Option, Fn)
/// or a regular key with optional modifiers (e.g. ⌃⌥Space).
struct Hotkey: Codable, Equatable, Sendable {
    var keyCode: UInt16
    /// Raw `CGEventFlags` restricted to `Hotkey.relevantModifiers`. Ignored for modifier-only keys.
    var modifiers: UInt64

    static let `default` = Hotkey(keyCode: 0x3D, modifiers: 0) // Right Option

    static let relevantModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    /// Modifier keys usable on their own, with the device-specific flag bit that tells
    /// left from right (NX_DEVICE*KEYMASK), or the Fn flag.
    static let modifierKeys: [UInt16: (name: String, flag: UInt64)] = [
        0x37: ("Left ⌘", 0x08), 0x36: ("Right ⌘", 0x10),
        0x3A: ("Left ⌥", 0x20), 0x3D: ("Right ⌥", 0x40),
        0x3B: ("Left ⌃", 0x01), 0x3E: ("Right ⌃", 0x2000),
        0x38: ("Left ⇧", 0x02), 0x3C: ("Right ⇧", 0x04),
        0x3F: ("Fn 🌐", CGEventFlags.maskSecondaryFn.rawValue),
    ]

    var isModifierOnly: Bool { Hotkey.modifierKeys[keyCode] != nil }

    /// For modifier-only hotkeys: is the key currently held, given the event flags?
    func isModifierHeld(in flags: CGEventFlags) -> Bool {
        guard let flag = Hotkey.modifierKeys[keyCode]?.flag else { return false }
        return flags.rawValue & flag != 0
    }

    func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        keyCode == self.keyCode
            && flags.intersection(Hotkey.relevantModifiers).rawValue == modifiers
    }

    var displayName: String {
        if let mod = Hotkey.modifierKeys[keyCode] { return mod.name }
        let flags = CGEventFlags(rawValue: modifiers)
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        return s + Hotkey.keyName(keyCode)
    }

    static func keyName(_ code: UInt16) -> String {
        let names: [UInt16: String] = [
            0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G",
            0x04: "H", 0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N",
            0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T", 0x20: "U",
            0x09: "V", 0x0D: "W", 0x07: "X", 0x10: "Y", 0x06: "Z",
            0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7",
            0x1C: "8", 0x19: "9", 0x1D: "0",
            0x31: "Space", 0x24: "Return", 0x30: "Tab", 0x33: "Delete", 0x35: "Esc",
            0x32: "`", 0x1B: "-", 0x18: "=", 0x21: "[", 0x1E: "]", 0x2A: "\\",
            0x29: ";", 0x27: "'", 0x2B: ",", 0x2F: ".", 0x2C: "/",
            0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
            0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
            0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18",
            0x50: "F19", 0x5A: "F20",
        ]
        return names[code] ?? "Key \(code)"
    }
}

extension Hotkey {
    private static let functionKeys: Set<UInt16> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
        0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
    ]

    /// Plain letters/space without modifiers would hijack normal typing.
    var isAcceptable: Bool {
        isModifierOnly || modifiers != 0 || Hotkey.functionKeys.contains(keyCode)
    }
}
