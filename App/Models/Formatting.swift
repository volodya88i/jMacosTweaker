import Core
import Foundation

enum Format {
    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func temperature(_ celsius: Double?, unit: TemperatureUnit, withUnit: Bool = false) -> String {
        guard let celsius else { return String(localized: "N/A") }
        let value = unit == .celsius ? celsius : celsius * 9 / 5 + 32
        return "\(Int(value.rounded()))°" + (withUnit && unit == .fahrenheit ? "F" : "")
    }

    static func rpm(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number)
    }

    /// A stopped fan is not a broken reading.
    static func fanSpeed(_ value: Double) -> String {
        value == 0 ? String(localized: "Stopped") : "\(rpm(value)) rpm"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case ..<1000: String(format: "%.0f B/s", bytesPerSecond)
        case ..<1_000_000: String(format: "%.0f KB/s", bytesPerSecond / 1000)
        case ..<1_000_000_000: String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        default: String(format: "%.2f GB/s", bytesPerSecond / 1_000_000_000)
        }
    }

    /// Short enough for the menu bar.
    static func compactRate(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case ..<1000: String(format: "%.0fB", bytesPerSecond)
        case ..<1_000_000: String(format: "%.0fK", bytesPerSecond / 1000)
        case ..<1_000_000_000: String(format: "%.1fM", bytesPerSecond / 1_000_000)
        default: String(format: "%.1fG", bytesPerSecond / 1_000_000_000)
        }
    }

    static func display(celsius: Double, unit: TemperatureUnit) -> Double {
        unit == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    static func celsius(display: Double, unit: TemperatureUnit) -> Double {
        unit == .celsius ? display : (display - 32) * 5 / 9
    }

    static func watts(_ value: Double?) -> String {
        guard let value else { return String(localized: "N/A") }
        return String(format: "%.1f W", value)
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }

    static func megahertz(_ value: Double?) -> String {
        guard let value else { return String(localized: "N/A") }
        return "\(Int(value.rounded()).formatted(.number)) MHz"
    }

    static func duration(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    static func sensorValue(_ value: Double, kind: SensorKind, unit: TemperatureUnit) -> String {
        switch kind {
        case .temperature: temperature(value, unit: unit)
        case .voltage: String(format: "%.3f V", value)
        case .current: String(format: "%.3f A", value)
        case .power: String(format: "%.1f W", value)
        }
    }
}

extension BatteryState {
    var title: String {
        switch self {
        case .charging: String(localized: "Charging")
        case .discharging: String(localized: "On battery")
        case .notCharging: String(localized: "Not charging")
        }
    }
}

extension MemoryPressure {
    var title: String {
        switch self {
        case .normal: String(localized: "Normal")
        case .warning: String(localized: "Warning")
        case .critical: String(localized: "Critical")
        case .unknown: String(localized: "N/A")
        }
    }
}

extension SensorGroup {
    var title: String {
        switch self {
        case .cpuPerformance: String(localized: "P-cores (performance)")
        case .cpuEfficiency: String(localized: "E-cores (efficiency)")
        case .gpu: String(localized: "GPU")
        case .soc: String(localized: "SoC")
        case .ssd: String(localized: "SSD")
        case .battery: String(localized: "Battery")
        case .enclosure: String(localized: "Enclosure")
        case .electrical: String(localized: "Voltage, current and power")
        case .other: String(localized: "Other")
        }
    }
}
