import Foundation

public protocol SensorSampling: Sendable {
    /// All usable sensors, found once and cached. Vanished sensors simply stop appearing in readings.
    func descriptors() -> [SensorDescriptor]
    /// `full` reads every temperature. Otherwise only the groups used in summaries are read.
    func sampleTemperatures(full: Bool) -> [SensorReading]
    func sampleElectrical() -> [SensorReading]
    /// Changes whenever `descriptors()` changes, so callers know to fetch the list again.
    var catalogRevision: Int { get }
}

public extension SensorSampling {
    var catalogRevision: Int { 0 }
}

/// Combines SMC and HID sensors, and filters garbage: this Mac really does report -9200 °C, NaN and fixed placeholder
/// values. Placeholders are rejected sample by sample, because they mean "powered down", not "broken".
///
/// A sensor that shows no real value when the list is built, for example because the GPU is asleep, is kept aside and
/// checked again now and then. It joins the list the first time it reports a real temperature, so a Mac that starts idle
/// does not lose its GPU sensors for the whole session.
public final class SensorSampler: SensorSampling, @unchecked Sendable {
    /// How often sensors that have not yet shown a real value are read again. A dead key costs one read per interval.
    public static let dormantRecheck: TimeInterval = 10

    private struct SMCEntry {
        let key: SMCKey
        let id: SensorID
        let group: SensorGroup
    }

    private struct HIDEntry {
        let group: SensorGroup
        let name: String
    }

    private struct Catalog {
        var descriptors: [SensorDescriptor] = []
        var smcActive: [SMCEntry] = []
        var smcDormant: [SMCEntry] = []
        var hidActive: [String: SensorGroup] = [:]
        var hidDormant: [String: HIDEntry] = [:]
    }

    private let smc: (any SMCReading)?
    private let hid: (any HIDSensorReading)?
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var catalog: Catalog?
    private var lastDormantCheck = -TimeInterval.infinity
    private var revision = 0

    public init(
        smc: (any SMCReading)?, hid: (any HIDSensorReading)?,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.smc = smc
        self.hid = hid
        self.clock = clock
    }

    public var catalogRevision: Int {
        lock.withLock { revision }
    }

    public func descriptors() -> [SensorDescriptor] {
        lock.withLock { currentCatalog().descriptors }
    }

    public func sampleTemperatures(full: Bool) -> [SensorReading] {
        lock.withLock {
            var catalog = currentCatalog()
            let now = clock()
            let recheck = now - lastDormantCheck >= Self.dormantRecheck && !(catalog.smcDormant.isEmpty && catalog.hidDormant.isEmpty)
            if recheck { lastDormantCheck = now }

            var candidates: [SensorPlausibility.Candidate] = []
            candidates.reserveCapacity(catalog.smcActive.count)
            for entry in catalog.smcActive where full || Self.isSummaryGroup(entry.group) {
                guard let value = smc?.number(entry.key) else { continue }
                candidates.append(.init(id: entry.id, group: entry.group, value: value))
            }
            if recheck {
                for entry in catalog.smcDormant where full || Self.isSummaryGroup(entry.group) {
                    guard let value = smc?.number(entry.key) else { continue }
                    candidates.append(.init(id: entry.id, group: entry.group, value: value))
                }
            }

            var wanted = Set(catalog.hidActive.filter { full || Self.isSummaryGroup($0.value) }.keys)
            if recheck { wanted.formUnion(catalog.hidDormant.filter { full || Self.isSummaryGroup($0.value.group) }.keys) }
            if !wanted.isEmpty {
                for reading in hid?.read(kind: .temperature, ordinals: wanted) ?? [] {
                    let identity = "\(reading.name)#\(reading.ordinal)"
                    let group = catalog.hidActive[identity] ?? catalog.hidDormant[identity]?.group ?? SensorCatalog.group(hidName: reading.name)
                    candidates.append(.init(id: .hid(.temperature, identity: identity), group: group, value: reading.value))
                }
            }

            let screened = SensorPlausibility.screen(candidates)
            if recheck, promote(Set(screened.accepted.map(\.id)), in: &catalog) {
                self.catalog = catalog
                revision += 1
            }
            return screened.accepted
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

    /// Moves dormant sensors that just reported a real value into the list. Returns whether anything moved.
    private func promote(_ accepted: Set<SensorID>, in catalog: inout Catalog) -> Bool {
        var changed = false
        let woken = catalog.smcDormant.filter { accepted.contains($0.id) }
        if !woken.isEmpty {
            catalog.smcDormant.removeAll { accepted.contains($0.id) }
            catalog.smcActive.append(contentsOf: woken)
            catalog.descriptors.append(contentsOf: woken.map { entry in
                SensorDescriptor(id: entry.id, name: SensorCatalog.smcName(key: entry.key.description, group: entry.group), group: entry.group, kind: .temperature)
            })
            changed = true
        }
        for (identity, entry) in catalog.hidDormant where accepted.contains(.hid(.temperature, identity: identity)) {
            catalog.hidDormant[identity] = nil
            catalog.hidActive[identity] = entry.group
            catalog.descriptors.append(SensorDescriptor(id: .hid(.temperature, identity: identity), name: entry.name, group: entry.group, kind: .temperature))
            changed = true
        }
        return changed
    }

    private func currentCatalog() -> Catalog {
        if let catalog { return catalog }
        let built = buildCatalog()
        catalog = built
        lastDormantCheck = clock()
        return built
    }

    /// Every temperature key that can be read is kept. Those with a real value now are listed; the rest wait.
    private func buildCatalog() -> Catalog {
        var result = Catalog()
        var smcEntries: [SensorID: SMCEntry] = [:]
        var hidEntries: [SensorID: (identity: String, entry: HIDEntry)] = [:]
        var candidates: [SensorPlausibility.Candidate] = []
        if let smc, let count = try? smc.keyCount() {
            for index in 0..<count {
                guard let key = try? smc.key(at: index) else { continue }
                let name = key.description
                guard SensorCatalog.isListedTemperatureKey(name), let value = smc.number(key), value.isFinite else { continue }
                let entry = SMCEntry(key: key, id: .smc(key), group: SensorCatalog.group(smcKey: name))
                smcEntries[entry.id] = entry
                candidates.append(.init(id: entry.id, group: entry.group, value: value))
            }
        }
        for reading in hid?.read(kind: .temperature, ordinals: nil) ?? [] where reading.value.isFinite {
            let identity = "\(reading.name)#\(reading.ordinal)"
            let id = SensorID.hid(.temperature, identity: identity)
            let entry = HIDEntry(group: SensorCatalog.group(hidName: reading.name), name: Self.hidDisplayName(reading))
            hidEntries[id] = (identity, entry)
            candidates.append(.init(id: id, group: entry.group, value: reading.value))
        }

        let live = Set(SensorPlausibility.screen(candidates).accepted.map(\.id))
        for candidate in candidates {
            if let entry = smcEntries[candidate.id] {
                if live.contains(entry.id) {
                    result.smcActive.append(entry)
                    result.descriptors.append(SensorDescriptor(
                        id: entry.id, name: SensorCatalog.smcName(key: entry.key.description, group: entry.group), group: entry.group, kind: .temperature
                    ))
                } else {
                    result.smcDormant.append(entry)
                }
            } else if let (identity, entry) = hidEntries[candidate.id] {
                if live.contains(candidate.id) {
                    result.hidActive[identity] = entry.group
                    result.descriptors.append(SensorDescriptor(id: candidate.id, name: entry.name, group: entry.group, kind: .temperature))
                } else {
                    result.hidDormant[identity] = entry
                }
            }
        }

        if smc?.number(Self.systemPowerKey) != nil {
            result.descriptors.append(SensorDescriptor(
                id: .smc(Self.systemPowerKey), name: "System power PSTR", group: .electrical, kind: .power
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
