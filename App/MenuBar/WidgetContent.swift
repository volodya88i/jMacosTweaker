import Core
import Foundation

/// What one module shows right now. Plain values, so the menu bar can skip redraws when nothing changed.
struct WidgetContent: Equatable {
    var module: Module
    var value: String
    /// 0...1 for bar and gauge styles.
    var fraction: Double?
    var level: ValueLevel = .normal
    /// Raw number in the module's unit, for thresholds and visibility rules.
    var rawValue: Double?
    /// Replaces the module's small label, so a chosen sensor says what it is.
    var label: String?
}

enum WidgetEvaluator {
    @MainActor
    static func content(for config: WidgetConfig, store: MonitorStore, unit: TemperatureUnit) -> WidgetContent {
        var result = WidgetContent(module: config.module, value: "–")
        switch config.module {
        case .cpu:
            if let usage = store.cpu.current?.usage { fill(&result, raw: usage * 100, fraction: usage, text: Format.percent(usage)) }
        case .memory:
            if let current = store.memory.current {
                fill(&result, raw: current.usage * 100, fraction: current.usage, text: Format.percent(current.usage))
                if current.pressure == .warning { result.level = .warning }
                if current.pressure == .critical { result.level = .critical }
            }
        case .gpu:
            if let usage = store.gpu.current?.device { fill(&result, raw: usage * 100, fraction: usage, text: Format.percent(usage)) }
        case .temperature:
            let pinned = config.pinnedSensor.flatMap { store.sensors.stats[$0]?.latest }
            if pinned != nil, let id = config.pinnedSensor { result.label = store.sensors.shortLabel(for: id) }
            if let celsius = pinned ?? store.sensors.summary?.hottest {
                fill(&result, raw: celsius, fraction: min(celsius / 100, 1), text: Format.temperature(celsius, unit: unit))
            }
        case .fans:
            if let rpm = store.fans.averageRPM {
                let top = store.fans.current.map(\.maximumRPM).max() ?? 0
                fill(&result, raw: rpm, fraction: top > 0 ? min(rpm / top, 1) : nil, text: Format.rpm(rpm))
            }
        case .battery:
            if let percent = store.battery.current?.percent {
                fill(&result, raw: Double(percent), fraction: Double(percent) / 100, text: "\(percent)%")
            }
        case .power:
            if let watts = store.battery.flow?.systemWatts {
                fill(&result, raw: watts, fraction: nil, text: String(format: "%.0f W", watts))
            }
        case .network:
            if let total = store.network.current?.total {
                fill(&result, raw: total / 1_000_000, fraction: nil, text: Format.compactRate(total))
            }
        case .disk:
            if let total = store.disk.current?.total {
                fill(&result, raw: total / 1_000_000, fraction: nil, text: Format.compactRate(total))
            }
        }
        if let level = level(raw: result.rawValue, config: config), level != .normal { result.level = level }
        return result
    }

    @MainActor
    static func recentHistory(_ module: Module, store: MonitorStore) -> [Float] {
        let history: History
        switch module {
        case .cpu: history = store.cpu.history
        case .memory: history = store.memory.history
        case .gpu: history = store.gpu.history
        case .temperature: history = store.sensors.temperatureHistory
        case .fans: history = store.fans.history
        case .battery, .power: history = store.battery.powerHistory
        case .network: history = store.network.history
        case .disk: history = store.disk.history
        }
        return Array(history.elements.suffix(24))
    }

    private static func fill(_ content: inout WidgetContent, raw: Double, fraction: Double?, text: String) {
        content.rawValue = raw
        content.fraction = fraction
        content.value = text
    }

    /// Battery is the one module where lower is worse.
    static func level(raw: Double?, config: WidgetConfig) -> ValueLevel? {
        guard let raw else { return nil }
        let inverted = config.module == .battery
        func crossed(_ limit: Double?) -> Bool {
            guard let limit else { return false }
            return inverted ? raw <= limit : raw >= limit
        }
        if crossed(config.criticalAt) { return .critical }
        if crossed(config.warningAt) { return .warning }
        return .normal
    }

    /// Whether a widget should be in the menu bar. `wasVisible` adds hysteresis so a value hovering near the limit
    /// does not make the item flap.
    static func isVisible(rule: VisibilityRule, raw: Double?, battery: BatterySnapshot?, wasVisible: Bool) -> Bool {
        let margin = wasVisible ? 2.0 : 0
        switch rule {
        case .always:
            return true
        case let .above(limit):
            guard let raw else { return wasVisible }
            return raw >= limit - margin
        case let .below(limit):
            guard let raw else { return wasVisible }
            return raw <= limit + margin
        case .whileCharging:
            return battery?.state == .charging
        case .onBattery:
            return battery.map { !$0.externalConnected } ?? false
        }
    }
}
