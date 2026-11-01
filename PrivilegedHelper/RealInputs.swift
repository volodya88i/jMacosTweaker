import Core
import Foundation
import HelperCore
import Shared

final class RealInputs: ControlInputs, @unchecked Sendable {
    let fanLimits: [Int: FanLimits]
    private let sensors: SensorSampler
    private let batteryReader: BatteryReader?
    private var groups: [SensorID: SensorGroup]?

    init(smc: any SMCReading) {
        let fans = FanReader(smc: smc).sample()
        fanLimits = Dictionary(uniqueKeysWithValues: fans.map { ($0.index, FanLimits(minimum: $0.minimumRPM, maximum: $0.maximumRPM)) })
        sensors = SensorSampler(smc: smc, hid: HIDSensorClient())
        batteryReader = BatteryReader(smc: smc)
    }

    /// Built on first use. Listing every sensor can be slow while system services are still starting at boot, and
    /// restoring defaults at startup must not wait for it. Only the helper's one control queue calls this.
    private func sensorGroups() -> [SensorID: SensorGroup] {
        if let groups { return groups }
        let built = Dictionary(sensors.descriptors().map { ($0.id, $0.group) }, uniquingKeysWith: { first, _ in first })
        groups = built
        return built
    }

    var hasBattery: Bool { batteryReader?.isPresent ?? false }

    func readings(full: Bool) -> [SensorReading] {
        sensors.sampleTemperatures(full: full)
    }

    func summary(_ readings: [SensorReading]) -> TemperatureSummary {
        let groups = sensorGroups()
        return TemperatureSummary.make(readings: readings) { groups[$0] }
    }

    func battery() -> ChargeInputs {
        let snapshot = batteryReader?.sample()
        return ChargeInputs(percent: snapshot?.percent, temperature: snapshot?.temperature, externalConnected: snapshot?.externalConnected ?? true, isCharging: snapshot.map { $0.state == .charging })
    }
}
