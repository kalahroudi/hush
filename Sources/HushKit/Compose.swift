// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What the Return key does in the message box. Return sends; Shift, Option or Control with Return starts a new line.
public enum ComposeKey {
    public enum Action: Equatable, Sendable { case send, newline }

    public static func action(shift: Bool, option: Bool, control: Bool) -> Action {
        shift || option || control ? .newline : .send
    }

    /// True when a key press is Tab or Shift+Tab meant to switch chats. Tab with Control, Option or Command, and Tab while an
    /// input method is composing, are left to the text view.
    public static func switchesChat(keyCode: UInt16, option: Bool, control: Bool, command: Bool, composing: Bool) -> Bool {
        keyCode == 48 && !option && !control && !command && !composing
    }

    public static let hint = "Return to send · Shift+Return for a new line"
}

/// Which incoming messages get a banner. Muted chats never reach this (the session drops them).
public enum BannerPolicy {
    public static func shouldShow(enabled: Bool, favoritesOnly: Bool, isFavorite: Bool) -> Bool {
        enabled && (!favoritesOnly || isFavorite)
    }
}
