// Settings ▸ Providers: on/off, refresh interval, subscription price and keys,
// one section per provider in card order.
import AppKit
import BurnrateCore
import SwiftUI

struct ProvidersPane: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onChange(of: model.focus, initial: true) { _, name in
                    guard let name else { return }
                    Task {
                        // the window may be opening: let the form lay out first
                        try? await Task.sleep(for: .milliseconds(250))
                        withAnimation { proxy.scrollTo(name, anchor: .top) }
                        try? await Task.sleep(for: .seconds(2))
                        if model.focus == name { model.focus = nil }
                    }
                }
        }
    }

    private var form: some View {
        Form {
            ForEach(Config.order, id: \.self) { name in
                ProviderSection(name: name)
                    .id(name)
            }
            Section {
                Text(
                    "Keys are stored in your login Keychain under “burnrate” and read through Apple’s security tool, "
                        + "so macOS doesn’t ask for access, not even after a rebuild. Any program running as you can read them. "
                        + "From Terminal: burnratectl secret set NAME."
                )
                .settingsFootnote()
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderSection: View {
    let name: String
    @Environment(SettingsModel.self) private var model
    @Environment(Store.self) private var store

    private static let titles = [
        "claude": "Claude Code", "codex": "Codex", "openrouter": "OpenRouter", "replicate": "Replicate",
        "higgsfield": "Higgsfield",
    ]
    private static let intervals: [TimeInterval] = [60, 120, 300, 600, 900, 1800, 3600]

    var body: some View {
        let pc = model.provider(name)
        Section {
            Toggle(isOn: Binding(get: { pc.enabled }, set: { v in model.edit { $0.providers[name, default: .init()].enabled = v } })) {
                Label(Self.titles[name] ?? name, systemImage: Boring.symbol(name))
                    .font(.headline)
                    .foregroundStyle(model.focus == name ? Color.accentColor : .primary)
                    .animation(.easeInOut, value: model.focus)
            }
            if pc.enabled {
                Picker("Refresh every", selection: Binding(get: { pc.interval }, set: { v in model.edit { $0.providers[name, default: .init()].interval = v } })) {
                    ForEach(Self.intervals + (Self.intervals.contains(pc.interval) ? [] : [pc.interval]), id: \.self) {
                        Text(Format.span(ms: Int64($0 * 1000)).lowercased()).tag($0)
                    }
                }
                if name == "claude" || name == "codex" { price(pc) }
                credentials
                status
            }
        }
    }

    private func price(_ pc: Config.ProviderConfig) -> some View {
        let item = store.total?.items.first { $0.name == name && $0.kind == "subscription" }
        let prompt = item?.priceFrom == "table" ? Format.usd(item?.usd ?? 0) + " (list price)" : "List price"
        return LabeledContent {
            TextField(
                "", value: Binding(get: { pc.monthlyUSD }, set: { v in model.edit { $0.providers[name, default: .init()].monthlyUSD = v } }),
                format: .currency(code: "USD"), prompt: Text(prompt)
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 140)
        } label: {
            Text("Monthly price")
            Text("Empty uses the plan’s list price; 0 leaves it out of the month total.")
        }
    }

    @ViewBuilder private var credentials: some View {
        switch name {
        case "claude":
            Note(text: "Uses Claude Code’s login from the Keychain; run claude once if the card asks.")
        case "codex":
            Note(text: "Uses the Codex CLI login; run codex login if the card asks.")
        case "higgsfield":
            Note(text: "Uses the higgsfield CLI login; run higgsfield login if the card asks.")
        case "openrouter":
            SecretRow(title: "API key", key: "OPENROUTER_API_KEY", prompt: "sk-or-v1-…")
            Note(text: "A management key also shows the balance.")
            Link("Create a key at openrouter.ai", destination: URL(string: "https://openrouter.ai/settings/keys")!)
        case "replicate":
            SecretRow(title: "Session cookie", key: "REPLICATE_SESSIONID", prompt: "sessionid", cookie: true)
            DisclosureGroup("Where to find the session cookie") {
                Text(
                    "Replicate’s API has no billing, so the account, spend and credit come from the web session. Sign in at replicate.com, "
                        + "open DevTools (⌥⌘I) ▸ Application ▸ Cookies ▸ replicate.com and copy the value of sessionid. "
                        + "A whole Cookie header pasted here works too. It expires now and then; the card says when."
                )
                .settingsFootnote()
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var status: some View {
        if let s = store.sources[name], s.status != .fetching {
            let msg = !s.hint.isEmpty ? s.hint : s.lastError
            LabeledContent("Status") {
                if msg.isEmpty {
                    Label("Working", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text(Scrub.text(msg).capitalized(with: nil))
                        .foregroundStyle(s.status == .ok ? Color.secondary : Color.orange)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }
}

private struct Note: View {
    let text: String

    var body: some View {
        Text(text).settingsFootnote()
    }
}

/// A stored key shows masked with Replace and Remove; a new one goes in through a SecureField.
private struct SecretRow: View {
    let title: String
    let key: String
    let prompt: String
    var cookie = false
    @Environment(SettingsModel.self) private var model
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        let stored = model.stored[key]
        LabeledContent(title) {
            if let stored, !editing {
                HStack {
                    Text(Keychain.mask(stored))
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .textSelection(.disabled)
                    Button("Replace") { editing = true }
                    Button("Remove", role: .destructive) { model.setSecret(key, nil) }
                }
            } else {
                HStack {
                    SecureField("", text: $draft, prompt: Text(prompt))
                        .labelsHidden()
                        .frame(minWidth: 140)
                        .onSubmit(commit)
                    if cookie {
                        Button("Paste") {
                            draft = NSPasteboard.general.string(forType: .string) ?? ""
                            commit()
                        }
                        .help("Paste the sessionid or a whole Cookie header from the clipboard")
                    }
                    Button("Save", action: commit).disabled(draft.isEmpty)
                    if stored != nil {
                        Button("Cancel") {
                            editing = false; draft = ""
                        }
                    }
                }
            }
        }
    }

    private func commit() {
        let v = cookie ? Keychain.sessionID(from: draft) : draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        model.setSecret(key, v)
        draft = ""
        editing = false
    }
}
