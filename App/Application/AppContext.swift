import Core
import Foundation
import Observation
import SwiftUI

/// Raw values are kept from earlier versions, because snapshot file names and saved state use them.
enum WindowSection: String, CaseIterable, Identifiable {
    case dashboard, fans, sensors, performance, battery, widgets, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: String(localized: "Overview")
        case .fans: String(localized: "Fans")
        case .sensors: String(localized: "Sensors")
        case .performance: String(localized: "Performance")
        case .battery: String(localized: "Battery")
        case .widgets: String(localized: "Menu Bar")
        case .settings: String(localized: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .fans: "fan.fill"
        case .sensors: "thermometer.medium"
        case .performance: "cpu.fill"
        case .battery: "battery.75percent"
        case .widgets: "menubar.rectangle"
        case .settings: "gearshape.fill"
        }
    }

    /// Icon tile color in the sidebar, in the manner of System Settings.
    var tint: Color {
        switch self {
        case .dashboard: .blue
        case .fans: .cyan
        case .sensors: .red
        case .performance: .orange
        case .battery: .green
        case .widgets: .indigo
        case .settings: .gray
        }
    }

    /// Sidebar groups: what the Mac is doing, what can be changed, and the app itself.
    static let monitoring: [WindowSection] = [.dashboard, .sensors, .performance, .battery]
    static let control: [WindowSection] = [.fans]
    static let app: [WindowSection] = [.widgets, .settings]
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
    var dataTint: Color { Tokens.accent(settings.stored.accent) }

    /// Sections that exist on this Mac. A Mac without fans or a battery has no page for them.
    func isAvailable(_ section: WindowSection) -> Bool {
        switch section {
        case .fans: store.availability.hasFans
        case .battery: store.availability.hasBattery
        default: true
        }
    }
}
