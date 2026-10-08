// Look B "Boring": system fonts, SF Symbols, the system accent, light or dark.
// Glass lives only on the control layer (toolbar, menu bar panel); content is opaque.
import AppKit
import BurnrateCore
import SwiftUI

enum Boring {
    /// Grouped background and the card on it, like System Settings.
    static let canvas = Color(nsColor: dynamic(light: 0xF2F2F5, dark: 0x1C1C1E))
    static let card = Color(nsColor: dynamic(light: 0xFFFFFF, dark: 0x2C2C2E))

    static func fill(_ l: Level) -> Color {
        switch l {
        case .normal: .accentColor
        case .warn: .orange
        case .crit: .red
        }
    }

    /// Value text: colour only when it matters; warn stays on the bar.
    static func text(_ l: Level, hasBar: Bool) -> Color {
        switch l {
        case .crit: .red
        case .warn: hasBar ? .primary : .orange
        case .normal: .primary
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

    /// Provider glyphs; anything unknown gets a neutral one.
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

    /// "OCTOBER" spelled out from "2026-10".
    static func monthName(_ ym: String) -> String {
        let p = ym.split(separator: "-")
        guard p.count == 2, let m = Int(p[1]), (1...12).contains(m) else { return ym }
        return Calendar.current.standaloneMonthSymbols[m - 1]
    }

    /// "5h", "7d", "Fable": the panel's narrow label column.
    static func shortLabel(_ label: String) -> String {
        let s = MenuSummary.shortLabel(label)
        return s.first?.isNumber == true ? s.lowercased() : Format.sentence(s)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}

/// Thin capsule bar with an optional tick where the window's time stands.
struct CapsuleBar: View {
    let fill: Double
    let color: Color
    var elapsed: Double?
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 6
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(contrast == .increased ? 0.35 : 0.18))
                Capsule().fill(color)
                    .frame(width: max(height, geo.size.width * min(1, max(0, fill))))
                    .opacity(fill > 0 ? 1 : 0)
                if let elapsed {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(contrast == .increased ? 0.8 : 0.4))
                        .frame(width: 2, height: height + 4)
                        .offset(x: geo.size.width * min(1, max(0, elapsed / 100)) - 1)
                        .help("\(Int(elapsed.rounded()))% of the window gone")
                }
            }
            .frame(height: geo.size.height)
            .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: fill)
        }
        .frame(height: height + 4)
        .accessibilityHidden(true)
    }
}

/// "● 111% by reset": the forecast in words; a click explains it.
struct BoringPace: View {
    let gauge: Meter
    @State private var showTip = false

    var body: some View {
        Button {
            showTip.toggle()
        } label: {
            HStack(spacing: 5) {
                Circle().fill(Boring.pace(gauge.paceLevel)).frame(width: 6, height: 6)
                Text("\(Int((gauge.pace ?? 0).rounded()))% by reset")
                    .underline(pattern: .dot, color: .secondary.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Format.paceTip(gauge) ?? "Forecast at reset")
        .accessibilityLabel(Format.paceTip(gauge) ?? "Forecast at reset")
        .popover(isPresented: $showTip, arrowEdge: .bottom) {
            PaceExplainer(gauge: gauge, color: Boring.pace)
        }
    }
}

/// The bare pace dot of the menu panel: a click opens the same explainer.
struct BoringPaceDot: View {
    let gauge: Meter
    @State private var showTip = false

    var body: some View {
        Button {
            showTip.toggle()
        } label: {
            Circle()
                .fill(gauge.pace == nil ? .clear : Boring.pace(gauge.paceLevel))
                .frame(width: 7, height: 7)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .padding(-5.5)  // a bigger hit area, the same layout
        }
        .buttonStyle(.plain)
        .pointerStyle(gauge.pace == nil ? .default : .link)
        .disabled(gauge.pace == nil)
        .help(Format.paceTip(gauge) ?? "")
        .accessibilityLabel(Format.paceTip(gauge) ?? "Forecast at reset")
        .popover(isPresented: $showTip, arrowEdge: .bottom) {
            PaceExplainer(gauge: gauge, color: Boring.pace)
        }
        .frame(width: 10)
    }
}
