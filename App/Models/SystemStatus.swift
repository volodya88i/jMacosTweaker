import Core
import Foundation

/// The one line that answers "is everything OK?". A healthy system says so plainly and quietly.
@MainActor
enum SystemStatus {
    nonisolated static let hotCelsius = 95.0
    /// Where bars turn orange. Apple Silicon runs into the 80s under sustained load, so this is a hint, not an alarm.
    nonisolated static let warmCelsius = 85.0
    nonisolated static let lowBatteryPercent = 10

    static func line(store: MonitorStore, unit: TemperatureUnit) -> (text: String, level: ValueLevel) {
        if let hottest = store.sensors.summary?.hottest, hottest >= hotCelsius {
            return (String(localized: "Running hot: \(Format.temperature(hottest, unit: unit))"), .critical)
        }
        switch store.memory.current?.pressure {
        case .critical: return (String(localized: "Memory pressure is critical"), .critical)
        case .warning: return (String(localized: "Memory pressure is elevated"), .warning)
        default: break
        }
        if let battery = store.battery.current, battery.state == .discharging, battery.percent <= lowBatteryPercent {
            return (String(localized: "Battery low: \(battery.percent)%"), .warning)
        }
        return (String(localized: "All normal"), .normal)
    }
}
