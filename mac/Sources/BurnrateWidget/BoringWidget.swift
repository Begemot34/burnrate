// Boring widget: system fonts, SF Symbols and colours, like the app's Boring look.
import BurnrateCore
import SwiftUI
import WidgetKit

enum BoringWidget {
    static func fill(_ l: Level) -> Color {
        switch l {
        case .normal: .accentColor
        case .warn: .orange
        case .crit: .red
        }
    }

    static func text(_ l: Level) -> Color {
        switch l {
        case .normal: .primary
        case .warn: .orange
        case .crit: .red
        }
    }

    static func pace(_ level: String?) -> Color {
        switch level {
        case "under": .cyan
        case "on": .green
        case "over": .red
        default: .secondary
        }
    }

    /// The same glyphs as the app's cards.
    static func symbol(_ name: String) -> String {
        switch name {
        case "claude": "sparkle"
        case "codex": "apple.terminal"
        case "openrouter": "arrow.triangle.branch"
        case "replicate": "cube"
        case "higgsfield": "film"
        default: "square.grid.2x2"
        }
    }

    /// "5h", "7d", "Fable": the narrow label column.
    static func shortLabel(_ label: String) -> String {
        label.first?.isNumber == true ? label.lowercased() : Format.sentence(label)
    }
}

/// Thin capsule bar with an optional tick where the window's time stands.
struct BoringBar: View {
    let used: Double
    let level: Level
    var elapsed: Double?
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(BoringWidget.fill(level))
                    .frame(width: max(height, geo.size.width * min(1, max(0, used / 100))))
                    .opacity(used > 0 ? 1 : 0)
                if let elapsed {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 2, height: height + 4)
                        .offset(x: geo.size.width * min(1, max(0, elapsed / 100)) - 1)
                }
            }
            .frame(height: geo.size.height)
        }
        .frame(height: height + 4)
        .accessibilityHidden(true)
    }
}

struct BoringStaleNote: View {
    let entry: SnapshotEntry

    var body: some View {
        Label("Not updated", systemImage: "exclamationmark.triangle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
        Text(entry.snapshot == nil ? "Open Burnrate" : "Last data " + Format.ago(ms: entry.ageMs))
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
}

struct BoringSmall: View {
    let entry: SnapshotEntry

    var body: some View {
        let lead = entry.snapshot?.lead
        let dim = entry.stale ? 0.5 : 1
        VStack(alignment: .leading, spacing: 0) {
            if case let (row, item)? = lead {
                Label(row.title, systemImage: BoringWidget.symbol(row.name))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .labelStyle(BoringIconLabel())
                    .opacity(dim)
                Text(item.value)
                    .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                    .minimumScaleFactor(0.5).lineLimit(1)
                    .foregroundStyle(BoringWidget.text(item.level))
                    .padding(.top, 4)
                    .opacity(dim)
                Text(item.isBalance ? Format.niceLabel(item.label) : Format.niceLabel(item.label) + " limit")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    .opacity(dim)
                Spacer(minLength: 4)
                if let used = item.used {
                    BoringBar(used: used, level: item.level, elapsed: item.elapsed).opacity(dim)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if entry.stale {
                        BoringStaleNote(entry: entry)
                    } else {
                        if let ms = entry.left(item.resetAt) {
                            Text("Resets in " + Format.span(ms: ms))
                        }
                        if let pace = item.pace {
                            HStack(spacing: 5) {
                                Circle().fill(BoringWidget.pace(item.paceLevel)).frame(width: 7, height: 7)
                                Text("\(Int(pace.rounded()))% by reset")
                            }
                        }
                    }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .padding(.top, 6)
            } else {
                Label("Burnrate", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .labelStyle(BoringIconLabel())
                Spacer()
                if entry.stale {
                    BoringStaleNote(entry: entry)
                } else {
                    Text("No limits yet").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct BoringMedium: View {
    let entry: SnapshotEntry

    var body: some View {
        let dim = entry.stale ? 0.5 : 1
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(entry.snapshot?.limitRows ?? []) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(row.title, systemImage: BoringWidget.symbol(row.name))
                            .font(.caption.weight(.bold))
                            .labelStyle(BoringIconLabel())
                        ForEach(row.items) { item in
                            BoringLimitLine(entry: entry, item: item)
                        }
                    }
                    .opacity(row.stale && !entry.stale ? 0.5 : 1)
                }
                if entry.snapshot == nil {
                    BoringStaleNote(entry: entry)
                }
            }
            .opacity(dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1)
            VStack(alignment: .leading, spacing: 6) {
                Text("Balances").font(.caption.weight(.bold)).opacity(dim)
                ForEach(entry.snapshot?.balances ?? [], id: \.row.name) { row, item in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Text(item.value).font(.subheadline.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(BoringWidget.text(item.level)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .opacity(entry.stale || row.stale ? 0.5 : 1)
                }
                Spacer(minLength: 0)
                if entry.stale, entry.snapshot != nil {
                    Label(
                        Format.ago(ms: entry.ageMs).replacingOccurrences(of: " ago", with: " old"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption2.weight(.semibold)).foregroundStyle(.orange).monospacedDigit()
                    .labelStyle(BoringIconLabel())
                }
            }
            .frame(width: 86, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// "5h ━━━━━━━━━ 42% ● 3h 05m"
struct BoringLimitLine: View {
    let entry: SnapshotEntry
    let item: WidgetSnapshot.Item

    var body: some View {
        HStack(spacing: 7) {
            Text(BoringWidget.shortLabel(item.label))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: 32, alignment: .leading)
            BoringBar(used: item.used ?? 0, level: item.level, height: 5)
            Text(item.value)
                .font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(BoringWidget.text(item.level))
                .frame(width: 32, alignment: .trailing)
            Circle().fill(BoringWidget.pace(item.paceLevel)).frame(width: 6, height: 6)
                .opacity(item.pace == nil ? 0 : 1)
            Text(entry.left(item.resetAt).map { Format.left(ms: $0).lowercased() } ?? "")
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                .frame(width: 42, alignment: .trailing)
        }
        .frame(height: 15)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Format.niceLabel(item.label)) \(item.value)")
    }
}

/// Icon in the accent colour next to the text, tighter than the default label.
struct BoringIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(.tint).imageScale(.small)
            configuration.title
        }
    }
}
