// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A global keyboard shortcut: a virtual key code plus Carbon modifier bits.
public struct Shortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public static let cmd: UInt32 = 256, shift: UInt32 = 512, option: UInt32 = 2048, control: UInt32 = 4096
    public static let `default` = Shortcut(keyCode: 4, modifiers: control | option)   // ⌃⌥H
    public static let stackDefault = Shortcut(keyCode: 1, modifiers: control | option)   // ⌃⌥S, opens the favorites stack

    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

    /// From AppKit's `NSEvent.ModifierFlags.rawValue` (command 1<<20, shift 1<<17, option 1<<19, control 1<<18).
    public init(keyCode: UInt32, cocoaFlags: UInt) {
        var m: UInt32 = 0
        if cocoaFlags & (1 << 20) != 0 { m |= Self.cmd }
        if cocoaFlags & (1 << 17) != 0 { m |= Self.shift }
        if cocoaFlags & (1 << 19) != 0 { m |= Self.option }
        if cocoaFlags & (1 << 18) != 0 { m |= Self.control }
        self.init(keyCode: keyCode, modifiers: m)
    }

    /// A global shortcut needs command, control or option, or it would fire while typing.
    public var isValid: Bool { modifiers & (Self.cmd | Self.control | Self.option) != 0 && Self.keyNames[keyCode] != nil }

    public var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.cmd != 0 { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "?")
    }

    static let keyNames: [UInt32: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
        45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑",
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 42: "\\", 50: "`",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
