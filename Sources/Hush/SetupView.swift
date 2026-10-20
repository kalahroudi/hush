// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import HushKit

/// First-run guide. Detects every prerequisite, installs what it can with one button, and turns the rest
/// into copyable commands or links. Shown instead of empty screens until everything is ready.
struct SetupView: View {
    let model = AppModel.shared
    var compact = false
    private var state: SetupState { model.setupState }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Let's get Hush ready").font(.system(size: compact ? 15 : 18, weight: .semibold))
                Text("Two quick steps, then your chats appear. Nothing here leaves your Mac.").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(state.items) { item in
                    step(item)
                    if item.id != state.items.last?.id { Divider() }
                }
            }.padding(.horizontal, 12).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))

            // Manual steps: anything the app cannot do itself is shown here with a command to copy or a link to open.
            ForEach(state.missing.filter(manualStep)) { item in manual(item) }

            if state.canAutoInstall {
                HStack(spacing: 10) {
                    Button { model.setUpEverything() } label: {
                        HStack(spacing: 6) { if model.busy { ProgressView().controlSize(.small) }; Text(model.busy ? "Setting up…" : "Set everything up") }
                    }.buttonStyle(Pill(kind: .primary)).disabled(model.busy)
                    if model.busy, let t = model.runningTask { Text(t.lines.last ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) }
                }
                if !state.manualCommand.isEmpty {
                    HStack(spacing: 6) {
                        Text("Or run it yourself:").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Text(state.manualCommand).font(.system(size: 11.5, design: .monospaced))
                        CopyButton(text: state.manualCommand, label: "Copy command")
                    }
                }
            }
            Button("I did it, check again") { model.start() }.buttonStyle(Pill())
        }.frame(maxWidth: 520, alignment: .leading)
    }

    private func manualStep(_ item: Prereq) -> Bool {
        switch item.install {
        case .command, .link, .credentials: return true
        case .brew, .download, .none: return false
        }
    }

    @ViewBuilder private func manual(_ item: Prereq) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(item.title) needs you").font(.system(size: 13, weight: .semibold))
            if case .credentials = item.install {} else { Text(item.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            switch item.install {
            case .command(let cmd):
                HStack {
                    Text(cmd).font(.system(size: 11, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                    CopyButton(text: cmd, label: "Copy command")
                }
                Text("It may ask for your password, so run it in Terminal where you can see it.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            case .link(let url):
                if let u = URL(string: url) { Link("Open the download page", destination: u).font(.system(size: 12.5)) }
            case .credentials(let url):
                KeysForm(pageURL: url)
            default: EmptyView()
            }
        }.card()
    }

    private func step(_ item: Prereq) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.isMet ? "checkmark.circle.fill" : "circle").foregroundStyle(item.isMet ? Theme.ok : .secondary).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium))
                Text(item.isMet ? "Ready" : item.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(.vertical, 9)
    }
}

/// Asks for the Telegram API ID and hash. They are free, take a minute to get, and are saved in a private file on this Mac.
struct KeysForm: View {
    let pageURL: String
    private let model = AppModel.shared
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1. Sign in at my.telegram.org/apps with your phone number.\n2. Create an app (any name, e.g. Hush).\n3. Copy the API ID and API hash here.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let u = URL(string: pageURL) { Link("Open my.telegram.org/apps", destination: u).font(.system(size: 12.5)) }
            @Bindable var m = model
            TextField("API ID (a number)", text: $m.draftKeyId).textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced))
            SecureField("API hash (32 characters)", text: $m.draftKeyHash).textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced))
            if let e = error { Text(e).font(.system(size: 11.5)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
            Button("Save key") { error = model.saveKeys(id: model.draftKeyId, hash: model.draftKeyHash) }.buttonStyle(Pill(kind: .primary))
                .disabled(model.draftKeyId.isEmpty || model.draftKeyHash.isEmpty)
        }
    }
}
