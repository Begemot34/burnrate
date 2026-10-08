// Cyberpunk widget: black, JetBrains Mono, segmented bars, the system accent.
import AppKit
import BurnrateCore
import SwiftUI
import WidgetKit

enum Cyber {
    static let bg = Color(hex: 0x0A0A0A)
    static let line = Color(hex: 0x2A2A2A)
    static let text = Color(hex: 0xE8E8E8)
    static let muted = Color(hex: 0x8A8A8A)
    static let track = Color(hex: 0x1C1C1C)
    static let warn = Color(hex: 0xFF9F1C)
    static let crit = Color(hex: 0xFF3B1F)

    static func text(_ l: Level) -> Color {
        switch l {
        case .normal: text
        case .warn: warn
        case .crit: crit
        }
    }

    static func fill(_ l: Level) -> Color { l == .normal ? .accentColor : text(l) }

    static func pace(_ level: String?) -> Color {
        switch level {
        case "under": Color(hex: 0x3D8BFF)
        case "on": Color(hex: 0x2BD96B)
        case "over": crit
        default: muted
        }
    }

    /// The bundled mono, or the system one if registration failed.
    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        let name = bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular"
        if NSFont(name: name, size: size) != nil { return .custom(name, fixedSize: size).monospacedDigit() }
        return .system(size: size, weight: bold ? .bold : .regular, design: .monospaced).monospacedDigit()
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// Uppercase muted label with letter-spacing, like the panel's.
struct CyberLabel: View {
    let text: String
    var size: CGFloat = 10
    var tracking: CGFloat = 1.2
    var color = Cyber.muted
    var bold = false

    var body: some View {
        Text(text.uppercased()).font(Cyber.mono(size, bold: bold)).tracking(tracking).foregroundStyle(color)
            .lineLimit(1)
    }
}

/// Bar of 5 pt segments with 2 pt gaps.
struct CyberBar: View {
    let used: Double
    let level: Level
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let count = max(1, Int((geo.size.width + 2) / 7))
            // any use lights at least one segment, so 3% does not read as zero
            let on = used > 0 ? max(1, Int((Double(count) * min(100, used) / 100).rounded())) : 0
            HStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { i in
                    Rectangle().fill(i < on ? Cyber.fill(level) : Cyber.track)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct CyberStale: View {
    let entry: SnapshotEntry
    var size: CGFloat = 10

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(Cyber.warn).frame(width: size - 3, height: size - 3)
            CyberLabel(
                text: entry.snapshot == nil ? "OPEN BURNRATE.APP" : "STALE " + Format.age(ms: entry.ageMs),
                size: size, color: Cyber.warn, bold: true)
        }
    }
}

struct CyberSmall: View {
    let entry: SnapshotEntry

    var body: some View {
        let dim = entry.stale ? 0.5 : 1
        VStack(alignment: .leading, spacing: 0) {
            if case let (row, item)? = entry.snapshot?.lead {
                CyberLabel(text: row.title).opacity(dim)
                Text(item.value)
                    .font(Cyber.mono(40, bold: true)).minimumScaleFactor(0.5).lineLimit(1)
                    .foregroundStyle(Cyber.text(item.level))
                    .padding(.top, 8)
                    .opacity(dim)
                CyberLabel(text: item.label).opacity(dim)
                Spacer(minLength: 4)
                if let used = item.used {
                    CyberBar(used: used, level: item.level).opacity(dim)
                }
                Group {
                    if entry.stale {
                        CyberStale(entry: entry)
                    } else {
                        HStack(spacing: 6) {
                            if let ms = entry.left(item.resetAt) {
                                CyberLabel(text: Format.left(ms: ms), tracking: 0.6)
                            }
                            Spacer(minLength: 0)
                            if let pace = item.pace {
                                Text("→\(Int(pace.rounded()))%").font(Cyber.mono(11, bold: true))
                                    .foregroundStyle(Cyber.muted)
                                Circle().fill(Cyber.pace(item.paceLevel)).frame(width: 7, height: 7)
                            }
                        }
                    }
                }
                .padding(.top, 9)
            } else {
                CyberLabel(text: "BURNRATE", bold: true)
                Spacer()
                if entry.stale { CyberStale(entry: entry) } else { CyberLabel(text: "NO LIMITS YET") }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct CyberMedium: View {
    let entry: SnapshotEntry

    var body: some View {
        let dim = entry.stale ? 0.5 : 1
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entry.snapshot?.limitRows ?? []) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        CyberLabel(text: row.title, size: 9)
                        ForEach(row.items) { item in
                            CyberLimitLine(entry: entry, item: item)
                        }
                    }
                    .opacity(row.stale && !entry.stale ? 0.5 : 1)
                }
                if entry.snapshot == nil {
                    CyberStale(entry: entry)
                }
            }
            .opacity(dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Cyber.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 6) {
                CyberLabel(text: "Balance", size: 9).opacity(dim)
                ForEach(entry.snapshot?.balances ?? [], id: \.row.name) { row, item in
                    VStack(alignment: .leading, spacing: 0) {
                        CyberLabel(text: row.title, size: 9, tracking: 0.8)
                        Text(item.value.uppercased()).font(Cyber.mono(13, bold: true))
                            .foregroundStyle(Cyber.text(item.level)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .opacity(entry.stale || row.stale ? 0.5 : 1)
                }
                Spacer(minLength: 0)
                if entry.stale, entry.snapshot != nil {
                    CyberStale(entry: entry, size: 9)
                }
            }
            .frame(width: 88, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// "5H ▮▮▮▮▯▯▯ 42% ● 3H 05M"
struct CyberLimitLine: View {
    let entry: SnapshotEntry
    let item: WidgetSnapshot.Item

    var body: some View {
        HStack(spacing: 7) {
            CyberLabel(text: item.label, tracking: 0.6).frame(width: 38, alignment: .leading)
            CyberBar(used: item.used ?? 0, level: item.level, height: 8)
            Text(item.value).font(Cyber.mono(11, bold: true)).foregroundStyle(Cyber.text(item.level))
                .frame(width: 34, alignment: .trailing)
            Circle().fill(Cyber.pace(item.paceLevel)).frame(width: 6, height: 6)
                .opacity(item.pace == nil ? 0 : 1)
            CyberLabel(text: entry.left(item.resetAt).map { Format.left(ms: $0) } ?? "", tracking: 0)
                .frame(width: 46, alignment: .trailing)
        }
        .frame(height: 15)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Format.niceLabel(item.label)) \(item.value)")
    }
}
