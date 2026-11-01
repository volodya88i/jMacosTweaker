import Core
import Foundation
import Observation

enum WindowSection: String, CaseIterable, Identifiable {
    case dashboard, fans, sensors, performance, battery, widgets, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: String(localized: "Dashboard")
        case .fans: String(localized: "Fans")
        case .sensors: String(localized: "Sensors")
        case .performance: String(localized: "Performance")
        case .battery: String(localized: "Battery")
        case .widgets: String(localized: "Widgets")
        case .settings: String(localized: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .fans: "fan"
        case .sensors: "thermometer.medium"
        case .performance: "chart.bar"
        case .battery: "battery.75percent"
        case .widgets: "menubar.rectangle"
        case .settings: "slider.horizontal.3"
        }
    }
}

/// What views need from the app. Holds references only, so it never causes redraws itself.
@MainActor
@Observable
final class AppContext {
    let settings: AppSettings
    let store: MonitorStore
    let control: ControlModel
    var section = WindowSection.dashboard
    var modulesHiddenByMenuBar: [Module] = []
    @ObservationIgnored var openWindow: (WindowSection) -> Void = { _ in }
    @ObservationIgnored var closePanel: () -> Void = {}

    init(settings: AppSettings, store: MonitorStore, control: ControlModel) {
        self.settings = settings
        self.store = store
        self.control = control
    }

    var engine: SamplingEngine { store.engine }
    var unit: TemperatureUnit { settings.stored.temperatureUnit }
}
