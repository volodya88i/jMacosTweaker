import AppKit
import SwiftUI

/// The few values the native design needs beyond what the system provides. Everything else is a system color, material
/// or control, so the app follows the appearance, the accent color and Liquid Glass on macOS 26 and later by itself.
enum Tokens {
    /// Data tint for graphs and bars. "System" follows the user's accent color, as native apps do.
    static func accent(_ choice: AccentChoice) -> Color {
        switch choice {
        case .none: .accentColor
        case .blue: .blue
        case .violet: .purple
        case .teal: .teal
        case .green: .green
        case .pink: .pink
        case let .custom(hex): Color(nsColor: NSColor(hex: hex))
        }
    }

    /// Menu bar extras are monochrome unless the user picked a color on purpose.
    static func menuBarAccent(_ choice: AccentChoice) -> NSColor {
        choice == .none ? .labelColor : NSColor(accent(choice))
    }

    enum Size {
        static let cardRadius: CGFloat = 12
        static let cardPadding: CGFloat = 14
        static let pagePadding: CGFloat = 20
        static let panelWidth: CGFloat = 368
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
        let parts = [color.redComponent, color.greenComponent, color.blueComponent].map { UInt32(min(max($0, 0), 1) * 255 + 0.5) }
        return parts[0] << 16 | parts[1] << 8 | parts[2]
    }
}

extension EnvironmentValues {
    /// The data tint, resolved once at the root of each window or panel.
    @Entry var dataTint: Color = .accentColor
}

enum LevelColor {
    static func color(_ level: ValueLevel, fallback: Color) -> Color {
        switch level {
        case .normal: fallback
        case .warning: .orange
        case .critical: .red
        }
    }

    /// Temperature to level, using the same limits as the status line.
    static func temperatureLevel(_ celsius: Double?) -> ValueLevel {
        guard let celsius else { return .normal }
        if celsius >= SystemStatus.hotCelsius { return .critical }
        if celsius >= SystemStatus.warmCelsius { return .warning }
        return .normal
    }
}
