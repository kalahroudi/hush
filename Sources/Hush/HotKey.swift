// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import Carbon.HIToolbox
import HushKit

/// Registers the global shortcuts with Carbon's RegisterEventHotKey, which needs no accessibility permission.
@MainActor
enum HotKey {
    /// Each slot is one global shortcut with its own Carbon hotkey id.
    enum Slot: UInt32 { case open = 1, stack = 2 }

    private static var refs: [Slot: EventHotKeyRef] = [:]
    private static var handler: EventHandlerRef?
    private static var actions: [Slot: () -> Void] = [:]

    static func onPress(_ slot: Slot, _ action: @escaping () -> Void) { actions[slot] = action }

    /// Returns an error message when the shortcut is already taken by another app or the system.
    @discardableResult
    static func apply(_ s: Shortcut?, slot: Slot = .open) -> String? {
        if let r = refs.removeValue(forKey: slot) { UnregisterEventHotKey(r) }
        guard let s, s.isValid else { return nil }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                DispatchQueue.main.async { MainActor.assumeIsolated { Slot(rawValue: id.id).flatMap { HotKey.actions[$0] }?() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x48555348), id: slot.rawValue)   // 'HUSH'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[slot] = ref; return nil }
        return "\(s.display) is already used by another app. Pick a different shortcut."
    }
}

/// Click, press the new combination, done. Esc cancels. Needs at least one of ⌘ ⌃ ⌥.
struct ShortcutRecorder: View {
    let prefs = Prefs.shared
    var slot: HotKey.Slot = .open
    private var current: Shortcut? { slot == .open ? prefs.shortcut : prefs.stackShortcut }
    private var fallback: Shortcut { slot == .open ? .default : .stackDefault }
    private func set(_ s: Shortcut?) { slot == .open ? prefs.setShortcut(s) : prefs.setStackShortcut(s) }
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 8) {
            Button { recording ? stop() : start() } label: {
                Text(recording ? "Press keys…" : (current?.display ?? "None"))
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced)).frame(minWidth: 88)
            }.buttonStyle(Pill(kind: recording ? .primary : .plain))
            if !recording {
                Menu {
                    Button("Reset to \(fallback.display)") { set(fallback) }.disabled(current == fallback)
                    Button("Clear shortcut") { set(nil) }.disabled(current == nil)
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
            set(s); stop(); return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
