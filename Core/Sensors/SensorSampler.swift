import Foundation

public protocol SensorSampling: Sendable {
    /// All usable sensors, found once and cached. Vanished sensors simply stop appearing in readings.
    func descriptors() -> [SensorDescriptor]
    /// `full` reads every temperature. Otherwise only the groups used in summaries are read.
    func sampleTemperatures(full: Bool) -> [SensorReading]
    func sampleElectrical() -> [SensorReading]
}

/// Combines SMC and HID sensors, and filters garbage: this Mac really does report -9200 °C and NaN.
public final class SensorSampler: SensorSampling, @unchecked Sendable {
    private struct Catalog {
        var descriptors: [SensorDescriptor] = []
        var smcTemperatures: [(key: SMCKey, id: SensorID, group: SensorGroup)] = []
        var hidTemperatures: Set<String> = []
        var hidSummary: Set<String> = []
    }

    private let smc: (any SMCReading)?
    private let hid: (any HIDSensorReading)?
    private let lock = NSLock()
    private var catalog: Catalog?

    public init(smc: (any SMCReading)?, hid: (any HIDSensorReading)?) {
        self.smc = smc
        self.hid = hid
    }

    public func descriptors() -> [SensorDescriptor] {
        lock.withLock { currentCatalog().descriptors }
    }

    public func sampleTemperatures(full: Bool) -> [SensorReading] {
        lock.withLock {
            let catalog = currentCatalog()
            var result: [SensorReading] = []
            result.reserveCapacity(catalog.smcTemperatures.count)
            for entry in catalog.smcTemperatures where full || Self.isSummaryGroup(entry.group) {
                guard let value = smc?.number(entry.key), SensorCatalog.isPlausible(value, kind: .temperature) else { continue }
                result.append(SensorReading(id: entry.id, value: value))
            }
            let wanted = full ? catalog.hidTemperatures : catalog.hidSummary
            guard !wanted.isEmpty else { return result }
            for reading in hid?.read(kind: .temperature, ordinals: wanted) ?? []
            where SensorCatalog.isPlausible(reading.value, kind: .temperature) {
                result.append(SensorReading(id: .hid(.temperature, identity: "\(reading.name)#\(reading.ordinal)"), value: reading.value))
            }
            return result
        }
    }

    public func sampleElectrical() -> [SensorReading] {
        var result: [SensorReading] = []
        for (hidKind, kind) in [(HIDSensorKind.voltage, SensorKind.voltage), (.current, .current)] {
            for reading in hid?.read(kind: hidKind, ordinals: nil) ?? []
            where SensorCatalog.isPlausible(reading.value, kind: kind) {
                result.append(SensorReading(id: .hid(kind, identity: "\(reading.name)#\(reading.ordinal)"), value: reading.value))
            }
        }
        if let value = smc?.number(Self.systemPowerKey), SensorCatalog.isPlausible(value, kind: .power) {
            result.append(SensorReading(id: .smc(Self.systemPowerKey), value: value))
        }
        return result
    }

    /// `PSTR` is the only SMC power key offered. It tracks system load only roughly: on adapter it read 9.8 to 19.3 W
    /// against telemetry's 10.3 to 23.2 W. So it is listed as a sensor, and not used for the power figure.
    public static let systemPowerKey: SMCKey = "PSTR"

    private static func isSummaryGroup(_ group: SensorGroup) -> Bool {
        group.isCPU || group == .gpu || group == .ssd || group == .battery
    }

    private func currentCatalog() -> Catalog {
        if let catalog { return catalog }
        let built = buildCatalog()
        catalog = built
        return built
    }

    private func buildCatalog() -> Catalog {
        var result = Catalog()
        if let smc, let count = try? smc.keyCount() {
            for index in 0..<count {
                guard let key = try? smc.key(at: index) else { continue }
                let name = key.description
                guard SensorCatalog.isListedTemperatureKey(name),
                      let value = smc.number(key), SensorCatalog.isPlausible(value, kind: .temperature) else { continue }
                let group = SensorCatalog.group(smcKey: name)
                let id = SensorID.smc(key)
                result.smcTemperatures.append((key, id, group))
                result.descriptors.append(SensorDescriptor(
                    id: id, name: SensorCatalog.smcName(key: name, group: group), group: group, kind: .temperature
                ))
            }
            if smc.number(Self.systemPowerKey) != nil {
                result.descriptors.append(SensorDescriptor(
                    id: .smc(Self.systemPowerKey), name: "System power PSTR", group: .electrical, kind: .power
                ))
            }
        }
        for reading in hid?.read(kind: .temperature, ordinals: nil) ?? []
        where SensorCatalog.isPlausible(reading.value, kind: .temperature) {
            let identity = "\(reading.name)#\(reading.ordinal)"
            let group = SensorCatalog.group(hidName: reading.name)
            result.hidTemperatures.insert(identity)
            if Self.isSummaryGroup(group) { result.hidSummary.insert(identity) }
            result.descriptors.append(SensorDescriptor(
                id: .hid(.temperature, identity: identity), name: Self.hidDisplayName(reading), group: group, kind: .temperature
            ))
        }
        for (hidKind, kind) in [(HIDSensorKind.voltage, SensorKind.voltage), (.current, .current)] {
            for reading in hid?.read(kind: hidKind, ordinals: nil) ?? []
            where SensorCatalog.isPlausible(reading.value, kind: kind) {
                result.descriptors.append(SensorDescriptor(
                    id: .hid(kind, identity: "\(reading.name)#\(reading.ordinal)"),
                    name: Self.hidDisplayName(reading), group: .electrical, kind: kind
                ))
            }
        }
        return result
    }

    private static func hidDisplayName(_ reading: HIDServiceReading) -> String {
        reading.ordinal == 0 ? reading.name : "\(reading.name) (\(reading.ordinal + 1))"
    }
}
