// Look A "BLACK SITE": colors, fonts and the shared card styling.
import AppKit
import BurnrateCore
import SwiftUI

enum Theme {
    static let bg = Color(hex: 0x0A0A0A)
    static let panel = Color(hex: 0x111111)
    static let line = Color(hex: 0x2A2A2A)
    static let text = Color(hex: 0xE8E8E8)
    static let muted = Color(hex: 0x7A7A7A)
    /// The system accent, blue by default, as in Boring; text on it is white.
    static let accent = Color.accentColor
    static let warn = Color(hex: 0xFF9F1C)
    static let crit = Color(hex: 0xFF3B1F)
    static let track = Color(hex: 0x1C1C1C)
    static let lampOff = Color(hex: 0x3A3A3A)
    static let paceUnder = Color(nsColor: .systemCyan)  // not the accent: bars are blue now
    static let paceOn = Color(hex: 0x2BD96B)

    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        font(bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular", size, fallback: .monospaced, bold: bold)
    }

    static func display(_ size: CGFloat, bold: Bool = true) -> Font {
        font(bold ? "SpaceGrotesk-Bold" : "SpaceGrotesk-Medium", size, fallback: .default, bold: bold)
    }

    private static func font(_ name: String, _ size: CGFloat, fallback: Font.Design, bold: Bool) -> Font {
        if NSFont(name: name, size: size) != nil { return .custom(name, fixedSize: size).monospacedDigit() }
        return .system(size: size, weight: bold ? .bold : .regular, design: fallback).monospacedDigit()
    }

    static func color(_ l: Level) -> Color {
        switch l {
        case .normal: text
        case .warn: warn
        case .crit: crit
        }
    }

    static func pace(_ level: String?) -> Color {
        switch level {
        case "under": paceUnder
        case "on": paceOn
        case "over": crit
        default: muted
        }
    }

    static func fill(_ l: Level) -> Color { l == .normal ? accent : color(l) }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// Uppercase label text with letter-spacing in em, like the CSS.
struct Label11: View {
    let text: String
    var color: Color = Theme.muted
    var size: CGFloat = 11
    var em: CGFloat = 0.12
    var bold = false

    var body: some View {
        Text(text.uppercased())
            .font(Theme.mono(size, bold: bold))
            .tracking(size * em)
            .foregroundStyle(color)
    }
}
