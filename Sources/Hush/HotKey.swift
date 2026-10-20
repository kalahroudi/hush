// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import Carbon.HIToolbox
import HushKit

/// Registers the global shortcut with Carbon's RegisterEventHotKey, which needs no accessibility permission.
@MainActor
enum HotKey {
    private static var ref: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    static var onPress: (() -> Void)?

    /// Returns an error message when the shortcut is already taken by another app or the system.
    @discardableResult
    static func apply(_ s: Shortcut?) -> String? {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
        guard let s, s.isValid else { return nil }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.onPress?() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x48555348), id: 1)   // 'HUSH'
        let status = RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        return status == noErr ? nil : "\(s.display) is already used by another app. Pick a different shortcut."
    }
}

/// Click, press the new combination, done. Esc cancels. Needs at least one of ⌘ ⌃ ⌥.
struct ShortcutRecorder: View {
    let prefs = Prefs.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 8) {
            Button { recording ? stop() : start() } label: {
                Text(recording ? "Press keys…" : (prefs.shortcut?.display ?? "None"))
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced)).frame(minWidth: 88)
            }.buttonStyle(Pill(kind: recording ? .primary : .plain))
            if !recording {
                Menu {
                    Button("Reset to \(Shortcut.default.display)") { prefs.setShortcut(.default) }.disabled(prefs.shortcut == .default)
                    Button("Clear shortcut") { prefs.setShortcut(nil) }.disabled(prefs.shortcut == nil)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Reset or clear")
            }
        }
        .fixedSize()
        .onDisappear { stop() }
        .help(hint ?? "Click, then press the shortcut you want")
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }   // Esc
            let s = Shortcut(keyCode: UInt32(e.keyCode), cocoaFlags: e.modifierFlags.rawValue)
            guard s.isValid else { NSSound.beep(); return nil }
            prefs.setShortcut(s); stop(); return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
