import Core
import Foundation
import Observation
import Shared

struct FanSettings: Codable, Hashable, Sendable {
    var preset = FanPreset.system
    var constantPercent = 0.0
    var customCurve = FanPreset.balanced.curve ?? FanCurve(points: [])
    var sensor = ControlSensor.hottest
    var linked = true
    var perFan: [Int: FanPreset] = [:]
    var switchByPowerSource = false
    var presetOnAdapter = FanPreset.system
    var presetOnBattery = FanPreset.system
    var saved: [NamedPreset] = []
    /// How quickly curves follow a rise. Normal skips spikes shorter than 10 s.
    var response = FanResponse.normal

    init() {}

    /// Missing fields keep their defaults, so settings from an older version keep everything they had.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<Value: Decodable>(_ key: CodingKeys, _ fallback: Value) -> Value {
            (try? container.decodeIfPresent(Value.self, forKey: key)) ?? fallback
        }
        let base = FanSettings()
        preset = value(.preset, base.preset)
        constantPercent = value(.constantPercent, base.constantPercent)
        customCurve = value(.customCurve, base.customCurve)
        sensor = value(.sensor, base.sensor)
        linked = value(.linked, base.linked)
        perFan = value(.perFan, base.perFan)
        switchByPowerSource = value(.switchByPowerSource, base.switchByPowerSource)
        presetOnAdapter = value(.presetOnAdapter, base.presetOnAdapter)
        presetOnBattery = value(.presetOnBattery, base.presetOnBattery)
        saved = value(.saved, base.saved)
        response = value(.response, base.response)
    }
}

enum AccentChoice: Codable, Hashable, Sendable, CaseIterable {
    case none, blue, violet, teal, green, pink
    case custom(UInt32)

    /// The presets. Custom is offered separately through a color well. `none` follows the system accent color; the
    /// case keeps its name so settings saved by earlier versions still load.
    static let allCases: [AccentChoice] = [.none, .blue, .violet, .teal, .green, .pink]

    var title: String {
        switch self {
        case .none: String(localized: "System")
        case .blue: String(localized: "Blue")
        case .violet: String(localized: "Violet")
        case .teal: String(localized: "Teal")
        case .green: String(localized: "Green")
        case .pink: String(localized: "Pink")
        case .custom: String(localized: "Custom")
        }
    }
}

enum AppearanceChoice: String, Codable, CaseIterable, Sendable {
    case system, dark, light

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .dark: String(localized: "Dark")
        case .light: String(localized: "Light")
        }
    }
}

enum TemperatureUnit: String, Codable, CaseIterable, Sendable {
    case celsius, fahrenheit

    var title: String { self == .celsius ? "°C" : "°F" }
}

enum Module: String, Codable, CaseIterable, Identifiable, Sendable {
    case cpu, memory, gpu, temperature, fans, battery, power, network, disk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: String(localized: "CPU")
        case .memory: String(localized: "Memory")
        case .gpu: String(localized: "GPU")
        case .temperature: String(localized: "Temperature")
        case .fans: String(localized: "Fans")
        case .battery: String(localized: "Battery")
        case .power: String(localized: "Power")
        case .network: String(localized: "Network")
        case .disk: String(localized: "Disk")
        }
    }

    /// The tiny label in the menu bar.
    var shortLabel: String {
        switch self {
        case .cpu: String(localized: "CPU")
        case .memory: String(localized: "RAM")
        case .gpu: String(localized: "GPU")
        case .temperature: String(localized: "TEMP")
        case .fans: String(localized: "FAN")
        case .battery: String(localized: "BAT")
        case .power: String(localized: "PWR")
        case .network: String(localized: "NET")
        case .disk: String(localized: "DISK")
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "square.stack.3d.up"
        case .temperature: "thermometer.medium"
        case .fans: "fan"
        case .battery: "battery.75percent"
        case .power: "bolt"
        case .network: "network"
        case .disk: "internaldrive"
        }
    }

    var sources: Set<SampleSource> {
        switch self {
        case .cpu: [.cpu]
        case .memory: [.memory]
        case .gpu: [.gpu]
        case .temperature: [.temperatureSummary]
        case .fans: [.fans]
        case .battery: [.battery]
        case .power: [.battery, .power]
        case .network: [.network]
        case .disk: [.disk]
        }
    }

    /// The unit of thresholds and visibility values. Temperature is stored in °C and converted for display.
    var thresholdUnit: String {
        switch self {
        case .cpu, .memory, .gpu, .battery: "%"
        case .temperature: "°"
        case .fans: "rpm"
        case .power: "W"
        case .network, .disk: "MB/s"
        }
    }

    var allowedStyles: [WidgetStyle] {
        switch self {
        case .cpu, .memory, .gpu, .battery: WidgetStyle.allCases
        case .temperature, .fans: [.text, .iconValue, .sparkline, .bar, .gauge]
        case .power, .network, .disk: [.text, .iconValue, .sparkline]
        }
    }

    /// Default interval. Battery changes slowly and also gets OS notifications.
    var defaultInterval: TimeInterval {
        self == .battery ? 30 : 5
    }
}

enum WidgetStyle: String, Codable, CaseIterable, Sendable {
    case text, iconValue, bar, sparkline, gauge

    var title: String {
        switch self {
        case .text: String(localized: "Text")
        case .iconValue: String(localized: "Icon and value")
        case .bar: String(localized: "Mini bar")
        case .sparkline: String(localized: "Sparkline")
        case .gauge: String(localized: "Mini gauge")
        }
    }
}

enum VisibilityRule: Codable, Hashable, Sendable {
    case always
    /// Shown only at or above this value, in the module's own unit.
    case above(Double)
    case below(Double)
    case whileCharging
    case onBattery
}

struct WidgetConfig: Codable, Hashable, Identifiable, Sendable {
    var module: Module
    var enabled: Bool
    var style: WidgetStyle = .text
    var interval: TimeInterval
    /// Value at which the widget turns the warning or critical color. For Battery, lower is worse.
    var warningAt: Double?
    var criticalAt: Double?
    var visibility: VisibilityRule = .always
    /// Temperature module only: a pinned sensor. Nil shows the hottest.
    var pinnedSensor: SensorID?
    var showsLabel = true

    var id: Module { module }

    static func standard(_ module: Module) -> WidgetConfig {
        var config = WidgetConfig(module: module, enabled: module == .cpu || module == .memory, interval: module.defaultInterval)
        switch module {
        case .temperature:
            config.warningAt = 85
            config.criticalAt = 95
        case .battery:
            config.warningAt = 20
            config.criticalAt = 10
        default:
            break
        }
        return config
    }
}

/// User settings, stored as one JSON document in defaults so schema changes stay in one place.
@MainActor
@Observable
final class AppSettings {
    struct Stored: Codable, Sendable {
        var schema = 1
        var accent = AccentChoice.none
        var appearance = AppearanceChoice.system
        var temperatureUnit = TemperatureUnit.celsius
        var widgets = Module.allCases.map(WidgetConfig.standard)
        var combined = false
        var notifyHighTemperature = false
        var highTemperatureAt = 95.0
        var notifyChargeLimit = false
        var hasCompletedOnboarding = false
        var fan = FanSettings()
        var charge = ChargeRequest.off
        /// Off by default: until it is on, the app makes no network request.
        var checkForUpdates = false
        /// One-time changes already applied to this file. 1: notifications off by default (0.2.2).
        var migrations = Stored.currentMigrations

        static let currentMigrations = 1

        init() {}

        /// Missing fields keep their defaults, so a file from an older version still loads.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func value<Value: Decodable>(_ key: CodingKeys, _ fallback: Value) -> Value {
                (try? container.decodeIfPresent(Value.self, forKey: key)) ?? fallback
            }
            let base = Stored()
            schema = value(.schema, base.schema)
            accent = value(.accent, base.accent)
            appearance = value(.appearance, base.appearance)
            temperatureUnit = value(.temperatureUnit, base.temperatureUnit)
            widgets = value(.widgets, base.widgets)
            combined = value(.combined, base.combined)
            notifyHighTemperature = value(.notifyHighTemperature, base.notifyHighTemperature)
            highTemperatureAt = value(.highTemperatureAt, base.highTemperatureAt)
            notifyChargeLimit = value(.notifyChargeLimit, base.notifyChargeLimit)
            hasCompletedOnboarding = value(.hasCompletedOnboarding, base.hasCompletedOnboarding)
            fan = value(.fan, base.fan)
            charge = value(.charge, base.charge)
            checkForUpdates = value(.checkForUpdates, base.checkForUpdates)
            // A file without the field predates every migration.
            migrations = value(.migrations, 0)
        }
    }

    private static let key = "settings.v1"
    private let defaults: UserDefaults

    var stored: Stored {
        didSet { save() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = Self.normalized(decoded)
            // didSet does not run in init, so a migration is written here.
            if decoded.migrations < Stored.currentMigrations { save() }
        } else {
            stored = Stored()
        }
    }

    /// Adds modules introduced after the file was written, drops duplicates, and brings every number back into the range
    /// the UI can set. Settings files are imported from anywhere, and defaults can be edited by hand: an update interval
    /// of 0 would make the sampler spin.
    static func normalized(_ value: Stored) -> Stored {
        var result = value
        var seen = Set<Module>()
        result.widgets = value.widgets.filter { seen.insert($0.module).inserted }
        for module in Module.allCases where !seen.contains(module) {
            var config = WidgetConfig.standard(module)
            config.enabled = false
            result.widgets.append(config)
        }
        for index in result.widgets.indices {
            var config = result.widgets[index]
            config.interval = config.interval.isFinite ? min(max(config.interval, 1), 60) : config.module.defaultInterval
            if let value = config.warningAt, !value.isFinite { config.warningAt = nil }
            if let value = config.criticalAt, !value.isFinite { config.criticalAt = nil }
            switch config.visibility {
            case let .above(limit) where !limit.isFinite, let .below(limit) where !limit.isFinite:
                config.visibility = .always
            default:
                break
            }
            result.widgets[index] = config
        }
        result.highTemperatureAt = result.highTemperatureAt.isFinite ? min(max(result.highTemperatureAt, 40), 120) : 95
        let percent = result.fan.constantPercent
        result.fan.constantPercent = percent.isFinite ? min(max(percent, 0), 100) : 0
        if case .failure = CurveMath.validate(result.fan.customCurve) {
            result.fan.customCurve = FanPreset.balanced.curve ?? result.fan.customCurve
        }
        result.fan.saved.removeAll { preset in
            if case .failure = CurveMath.validate(preset.curve) { return true }
            return preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        result.fan.perFan = result.fan.perFan.filter { (0..<10).contains($0.key) }
        result.charge = ChargeStateMachine.clamped(result.charge)
        // Notifications are opt-in. Versions before 0.2.2 could leave them on, so they are turned off once; the owner can
        // turn them back on in Settings.
        if result.migrations < 1 {
            result.notifyHighTemperature = false
            result.notifyChargeLimit = false
        }
        result.migrations = max(result.migrations, Stored.currentMigrations)
        // Curves are never weaker than macOS. The helper enforces this too; lifting here keeps the editor honest.
        result.fan = retiringBuiltInPresets(result.fan)
        result.fan.customCurve = CurveMath.liftedToFloor(result.fan.customCurve)
        for index in result.fan.saved.indices {
            result.fan.saved[index].curve = CurveMath.liftedToFloor(result.fan.saved[index].curve)
        }
        return result
    }

    /// Silent, Balanced and Performance are no longer offered. One that is selected becomes the Custom curve and a saved
    /// curve of the same name, so nothing changes for the owner; elsewhere, such as per fan, they become Custom.
    static func retiringBuiltInPresets(_ fan: FanSettings) -> FanSettings {
        var result = fan
        if let curve = fan.preset.curve {
            result.customCurve = curve
            if !result.saved.contains(where: { $0.name == fan.preset.title }) {
                result.saved.append(NamedPreset(name: fan.preset.title, curve: curve, sensor: fan.sensor))
            }
            result.preset = .custom
        }
        result.perFan = fan.perFan.mapValues { $0.isRetired ? .custom : $0 }
        if fan.presetOnAdapter.isRetired { result.presetOnAdapter = .custom }
        if fan.presetOnBattery.isRetired { result.presetOnBattery = .custom }
        return result
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func updateWidget(_ module: Module, _ change: (inout WidgetConfig) -> Void) {
        guard let index = stored.widgets.firstIndex(where: { $0.module == module }) else { return }
        change(&stored.widgets[index])
    }

    func widget(_ module: Module) -> WidgetConfig {
        stored.widgets.first { $0.module == module } ?? .standard(module)
    }

    func moveWidget(_ module: Module, by offset: Int) {
        guard let index = stored.widgets.firstIndex(where: { $0.module == module }) else { return }
        let target = index + offset
        guard stored.widgets.indices.contains(target) else { return }
        stored.widgets.swapAt(index, target)
    }

    func exportData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(stored)
    }

    func importData(_ data: Data) -> Bool {
        guard let decoded = try? JSONDecoder().decode(Stored.self, from: data), decoded.schema == 1 else { return false }
        stored = Self.normalized(decoded)
        return true
    }
}
