import AppKit
import SwiftUI

/// Design tokens from DESIGN.md. Colors resolve per appearance, so views never branch on color scheme.
enum Tokens {
    private static func dynamic(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    static let background = dynamic(dark: 0x000000, light: 0xFFFFFF)
    static let selection = dynamic(dark: 0x1C1C1E, light: 0xF0F0F2)
    static let hairline = dynamic(dark: 0x1F1F22, light: 0xE5E5E7)
    static let control = dynamic(dark: 0x3A3A3C, light: 0xC7C7CC)
    static let track = dynamic(dark: 0x2C2C2E, light: 0xE5E5E7)
    static let textPrimary = dynamic(dark: 0xF5F5F7, light: 0x000000)
    static let textSecondary = dynamic(dark: 0x98989D, light: 0x6E6E73)
    static let textTertiary = dynamic(dark: 0x636366, light: 0x8E8E93)
    static let warning = dynamic(dark: 0xFF9F0A, light: 0xB25000)
    static let critical = dynamic(dark: 0xFF453A, light: 0xD70015)

    static func accent(_ choice: AccentChoice) -> NSColor {
        switch choice {
        case .none: textPrimary
        case .blue: dynamic(dark: 0x5B9BFF, light: 0x0A5FE0)
        case .violet: dynamic(dark: 0xA78BFA, light: 0x6D4AE0)
        case .teal: dynamic(dark: 0x2DD4BF, light: 0x0F8F80)
        case .green: dynamic(dark: 0x4ADE80, light: 0x15803D)
        case .pink: dynamic(dark: 0xF472B6, light: 0xC02672)
        case let .custom(hex): NSColor(hex: hex)
        }
    }

    enum Size {
        static let controlRadius: CGFloat = 6
        static let panelRadius: CGFloat = 10
        static let windowRow: CGFloat = 34
        static let panelRow: CGFloat = 30
        static let sidebarWidth: CGFloat = 200
        static let panelWidth: CGFloat = 340
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// The color as 0xRRGGBB, for storing a custom accent.
    var hexValue: UInt32 {
        let color = usingColorSpace(.sRGB) ?? self
        let parts = [color.redComponent, color.greenComponent, color.blueComponent].map { UInt32(($0 * 255).rounded()) }
        return parts[0] << 16 | parts[1] << 8 | parts[2]
    }
}

extension Color {
    static let tkBackground = Color(nsColor: Tokens.background)
    static let tkSelection = Color(nsColor: Tokens.selection)
    static let tkControl = Color(nsColor: Tokens.control)
    static let tkTrack = Color(nsColor: Tokens.track)
    static let tkPrimary = Color(nsColor: Tokens.textPrimary)
    static let tkSecondary = Color(nsColor: Tokens.textSecondary)
    static let tkTertiary = Color(nsColor: Tokens.textTertiary)
    static let tkWarning = Color(nsColor: Tokens.warning)
    static let tkCritical = Color(nsColor: Tokens.critical)
}

/// The accent resolved for views. Passed through the environment, so changing it does not touch data models.
struct LineStyle: Equatable {
    var line = Color.tkPrimary
    var divider = Color(nsColor: Tokens.hairline)
    var secondaryLine = Color.tkTertiary

    init() {}

    init(accent: AccentChoice, accentDividers: Bool) {
        let color = Tokens.accent(accent)
        line = Color(nsColor: color)
        if accent != .none, accentDividers {
            divider = Color(nsColor: color).opacity(0.35)
        }
    }
}

extension EnvironmentValues {
    @Entry var lineStyle = LineStyle()
}

enum LevelColor {
    static func color(_ level: ValueLevel, fallback: Color) -> Color {
        switch level {
        case .normal: fallback
        case .warning: .tkWarning
        case .critical: .tkCritical
        }
    }
}
