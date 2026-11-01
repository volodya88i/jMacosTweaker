import Core
import Foundation
import UserNotifications

/// Optional threshold notifications, with a cooldown. Holds sampling demand only while a notification is enabled.
@MainActor
final class AlertManager {
    private static let cooldown: TimeInterval = 15 * 60

    private let settings: AppSettings
    private let store: MonitorStore
    private var lastSent: [String: TimeInterval] = [:]
    private var lastDemand: [SampleDemand]?
    /// The active limit, supplied by whoever knows it.
    var chargeLimit: () -> Int? = { nil }

    init(settings: AppSettings, store: MonitorStore) {
        self.settings = settings
        self.store = store
    }

    func settingsChanged() {
        var demand: [SampleDemand] = []
        if settings.stored.notifyHighTemperature { demand.append(SampleDemand(sources: [.temperatureSummary], interval: 30)) }
        if settings.stored.notifyChargeLimit { demand.append(SampleDemand(sources: [.battery], interval: 60)) }
        guard demand != lastDemand else { return }
        if !demand.isEmpty, lastDemand?.isEmpty ?? true {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }
        lastDemand = demand
        let engine = store.engine
        Task { await engine.setDemands(owner: "alerts", demand) }
    }

    func evaluate() {
        if settings.stored.notifyHighTemperature, let hottest = store.sensors.summary?.hottest, hottest >= settings.stored.highTemperatureAt {
            send(id: "temperature", title: String(localized: "High temperature"), body: String(localized: "Hottest sensor: \(Format.temperature(hottest, unit: settings.stored.temperatureUnit))"))
        }
        if settings.stored.notifyChargeLimit, let limit = chargeLimit(), let percent = store.battery.current?.percent, percent >= limit {
            send(id: "chargeLimit", title: String(localized: "Charge limit reached"), body: String(localized: "Battery is at \(percent)%."))
        }
    }

    private func send(id: String, title: String, body: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastSent[id], now - last < Self.cooldown { return }
        lastSent[id] = now
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
