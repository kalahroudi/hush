// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import Carbon.HIToolbox
import HushKit

/// Registers global shortcuts with Carbon's RegisterEventHotKey, which needs no accessibility permission.
/// Each `HotKeySlot` owns one registration and one press callback.
@MainActor
enum HotKey {
    private static var refs: [HotKeySlot: EventHotKeyRef] = [:]
    private static var handler: EventHandlerRef?
    static var onPress: [HotKeySlot: () -> Void] = [:]

    /// Returns an error message when the shortcut is already taken by another app or the system.
    @discardableResult
    static func apply(_ s: Shortcut?, slot: HotKeySlot = .open) -> String? {
        if let r = refs.removeValue(forKey: slot) { UnregisterEventHotKey(r) }
        guard let s, s.isValid else { return nil }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                guard let event, GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                      let slot = HotKeySlot(rawValue: id.id) else { return noErr }
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.onPress[slot]?() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x48555348), id: slot.rawValue)   // 'HUSH'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[slot] = ref }
        return status == noErr ? nil : "\(s.display) is already used by another app. Pick a different shortcut."
    }
}

/// Click, press the new combination, done. Esc cancels. Needs at least one of ⌘ ⌃ ⌥.
struct ShortcutRecorder: View {
    let prefs = Prefs.shared
    var slot: HotKeySlot = .open
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    private var current: Shortcut? { slot == .open ? prefs.shortcut : prefs.stackShortcut }
    private var fallback: Shortcut { slot == .open ? .default : .stackDefault }
    private func set(_ s: Shortcut?) { if slot == .open { prefs.setShortcut(s) } else { prefs.setStackShortcut(s) } }

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
