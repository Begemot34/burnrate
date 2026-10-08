// Burnrate ▸ Settings… (⌘,), also the gear in the menu bar panel. Changes apply
// at once; the last pane is remembered.
import SwiftUI

struct SettingsView: View {
    enum Pane: String { case general, appearance, providers }

    @Environment(AppModel.self) private var app
    @AppStorage(Prefs.settingsTab) private var pane = Pane.general

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: .general) {
                GeneralPane()
            }
            Tab("Appearance", systemImage: "paintpalette", value: .appearance) {
                AppearanceSettings()
            }
            Tab("Providers", systemImage: "person.2.badge.key", value: .providers) {
                ProvidersPane()
                    .frame(height: 620)
            }
        }
        .frame(width: 520)
        .environment(app.settings)
        // read the files again each time the window opens: burnratectl may have changed them
        .onAppear { app.settings.load() }
    }
}

struct AppearanceSettings: View {
    @AppStorage(Look.key) private var look: Look = .initial

    var body: some View {
        Form {
            Picker("Look", selection: $look) {
                ForEach(Look.allCases) { l in
                    VStack(spacing: 6) {
                        Thumbnail(look: l)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        l == look ? Color.accentColor : .secondary.opacity(0.3),
                                        lineWidth: l == look ? 3 : 1)
                            }
                        Text(l.title)
                    }
                    .tag(l)
                }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            Text(
                "Boring follows the system: light or dark, accent colour, SF font and symbols, Liquid Glass. "
                    + "Cyberpunk is the dark look with mono type and LED bars. "
                    + "Also switchable from the window toolbar and View ▸ Look (⌥⌘L)."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

/// A miniature of one gauge row in the given look.
private struct Thumbnail: View {
    let look: Look

    var body: some View {
        Group {
            if look == .boring {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("5-hour").font(.caption)
                        Spacer()
                        Text("42%").font(.callout.weight(.semibold))
                    }
                    CapsuleBar(fill: 0.42, color: .accentColor)
                }
                .padding(10)
                .background(Boring.card, in: .rect(cornerRadius: 6, style: .continuous))
                .padding(8)
                .background(Boring.canvas)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label11(text: "5H WINDOW", size: 8)
                        Spacer()
                        Text("42%").font(Theme.mono(12, bold: true)).foregroundStyle(Theme.text)
                    }
                    BarView(fill: 0.42, color: Theme.accent, height: 8, cell: 4, gap: 1)
                }
                .padding(10)
                .background(Theme.panel)
                .padding(8)
                .background(Theme.bg)
                .environment(\.colorScheme, .dark)
            }
        }
        .frame(width: 150, height: 72)
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
    }
}
