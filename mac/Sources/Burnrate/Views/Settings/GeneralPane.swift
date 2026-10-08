// Settings ▸ General: login item, the pace forecast and the warning thresholds.
import BurnrateCore
import ServiceManagement
import SwiftUI

struct GeneralPane: View {
    @Environment(SettingsModel.self) private var model
    @AppStorage(Prefs.showPace) private var showPace = true
    // the user can switch it off in System Settings: read, never remembered
    @State private var login = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: loginBinding)
                if login == .requiresApproval {
                    LabeledContent("Waiting for approval in System Settings") {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    Text(loginError).font(.callout).foregroundStyle(.red)
                }
            }
            Section {
                Toggle("Show pace forecast", isOn: $showPace)
            } footer: {
                Text("Where a limit lands at its reset if usage keeps the current pace. The tick for the time gone stays on the bars.")
                    .settingsFootnote()
            }
            Section("Warnings") {
                let t = model.config.thresholds
                LabeledContent("Limits") {
                    NumberField(value: t.warnPct, unit: "%", color: .orange) { v in
                        model.edit { $0.thresholds.warnPct = min(max(v, 1), $0.thresholds.critPct) }
                    }
                    NumberField(value: t.critPct, unit: "%", color: .red) { v in
                        model.edit { $0.thresholds.critPct = min(max(v, $0.thresholds.warnPct), 100) }
                    }
                }
                LabeledContent("Balances below") {
                    NumberField(value: t.warnUSD, unit: "$", prefix: true, color: .orange) { v in
                        model.edit { $0.thresholds.warnUSD = max(v, $0.thresholds.critUSD) }
                    }
                    NumberField(value: t.critUSD, unit: "$", prefix: true, color: .red) { v in
                        model.edit { $0.thresholds.critUSD = min(max(v, 0), $0.thresholds.warnUSD) }
                    }
                }
            }
            Section {
                LabeledContent("Configuration") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Config.defaultDir)
                    }
                }
            } footer: {
                if let e = model.error {
                    Text(e).settingsFootnote().foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { login = SMAppService.mainApp.status }
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { login == .enabled || login == .requiresApproval },
            set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    loginError = nil
                } catch {
                    loginError = error.localizedDescription
                }
                login = SMAppService.mainApp.status
            })
    }
}

/// A short number with its unit and the colour it stands for; commits on Return or focus loss.
private struct NumberField: View {
    let value: Double
    let unit: String
    var prefix = false
    let color: Color
    let commit: (Double) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            if prefix { Text(unit).foregroundStyle(.secondary) }
            TextField(
                "", value: Binding(get: { value }, set: { commit($0) }), format: .number.precision(.fractionLength(0...2))
            )
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 48)
            if !prefix { Text(unit).foregroundStyle(.secondary) }
        }
    }
}

extension Text {
    func settingsFootnote() -> some View {
        font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
