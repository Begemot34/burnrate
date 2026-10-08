import BurnrateCore
import SwiftUI

/// The window: one of the two looks, with the Look switch in the toolbar.
struct RootView: View {
    @AppStorage(Look.key) private var look: Look = .initial
    @Environment(Store.self) private var store

    var body: some View {
        Group {
            switch look {
            case .boring: BoringRoot()
            case .cyberpunk: CyberRoot()
            }
        }
        .toolbar { toolbar }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(look == .cyberpunk ? .hidden : .automatic, for: .windowToolbar)
    }

    // Both looks lay the toolbar out in the same two slots of the same size, so
    // switching swaps the drawing and the switch stays under the pointer.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Group {
                if look == .boring { WindowTitle() } else { Label11(text: "LOOK ⌥⌘L", size: 10, em: 0.14) }
            }
            .padding(.leading, 4)
            // the Cyberpunk label names the switch, so it sits against it
            .frame(width: LookSwitch.titleWidth, alignment: look == .boring ? .leading : .trailing)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            Group {
                if look == .boring {
                    Picker("Look", selection: $look) {
                        ForEach(Look.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } else {
                    CyberLookSwitch(look: $look)
                }
            }
            .frame(width: LookSwitch.width)
            .help("Look ⌥⌘L")
        }
        .sharedBackgroundVisibility(look == .boring ? .automatic : .hidden)
    }
}

/// The Look switch's slot: Boring's glass segmented control in the toolbar,
/// which the Cyberpunk switch copies so neither moves on a switch.
enum LookSwitch {
    /// Fits "Updated 59 min ago", the widest title, so the switch never shifts.
    static let titleWidth: CGFloat = 112
    static let width: CGFloat = 184
    static let height: CGFloat = 36
}

/// "Burnrate" with the time of the last update under it, ticking.
private struct WindowTitle: View {
    @Environment(Store.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let age = ctx.date.timeIntervalSince(store.updatedAt)
            VStack(alignment: .leading, spacing: 0) {
                Text("Burnrate").font(.headline)
                Text("Updated " + Format.ago(ms: Int64(age * 1000)))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// CYBERPUNK | BORING, brutal: outlined cells, the chosen one filled with the accent.
struct CyberLookSwitch: View {
    @Binding var look: Look

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Look.allCases) { l in
                Button {
                    look = l
                } label: {
                    Text(l.title.uppercased())
                        .font(Theme.mono(12, bold: true))
                        .tracking(1.2)
                        .foregroundStyle(l == look ? .white : Theme.text)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(l == look ? Theme.accent : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(l == look ? .isSelected : [])
            }
        }
        .frame(height: LookSwitch.height)
        .overlay(Rectangle().strokeBorder(Theme.text, lineWidth: 1))
        .focusEffectDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Look")
    }
}

/// The Cyberpunk window, BLACK SITE.
struct CyberRoot: View {
    /// The debug snapshot lays the cards out flat instead of in a scroll view.
    var flat = false
    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            Theme.line.frame(height: 1)
            BackendBanner()
            CyberLowBanner()
            if flat {
                grid
            } else {
                ScrollView { grid }
                    .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .font(Theme.mono(13))
    }

    private var grid: some View {
        CardGrid(spacing: 1, minWidth: 330) {
            ForEach(store.ordered) { s in
                CardView(source: s)
            }
        }
        .redacted(reason: store.isPlaceholder ? .placeholder : [])
        .background(Theme.line)
        .padding(.bottom, 1)
        .background(Theme.line.frame(height: 1), alignment: .bottom)
    }

}
