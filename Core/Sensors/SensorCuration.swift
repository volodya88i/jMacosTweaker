import Foundation

/// A row on the default Sensors page: one real sensor, or an aggregate of several.
public struct CuratedSensor: Hashable, Sendable, Identifiable {
    public enum Aggregate: Hashable, Sendable {
        case average
        case maximum
    }

    public let id: SensorID
    public let name: String
    public let section: SensorGroup
    public let members: [SensorID]
    public let aggregate: Aggregate

    public init(id: SensorID, name: String, section: SensorGroup, members: [SensorID], aggregate: Aggregate) {
        self.id = id
        self.name = name
        self.section = section
        self.members = members
        self.aggregate = aggregate
    }

    /// Nil unless at least half the members have a current reading, so a partial read cannot skew an aggregate.
    public func value(from values: [SensorID: Double]) -> Double? {
        let present = members.compactMap { values[$0] }
        guard !present.isEmpty, present.count * 2 >= members.count else { return nil }
        switch aggregate {
        case .average: return present.reduce(0, +) / Double(present.count)
        case .maximum: return present.max()
        }
    }
}

/// Reduces hundreds of raw sensors to the handful people want. The raw list stays available behind a toggle.
public enum SensorCuration {
    public static func curated(from descriptors: [SensorDescriptor]) -> [CuratedSensor] {
        let temperatures = descriptors.filter { $0.kind == .temperature }
        func ids(_ group: SensorGroup, where matches: (SensorDescriptor) -> Bool = { _ in true }) -> [SensorID] {
            temperatures.filter { $0.group == group && matches($0) }.map(\.id)
        }
        var result: [CuratedSensor] = []
        func add(_ key: String, _ name: String, _ section: SensorGroup, _ members: [SensorID], _ aggregate: CuratedSensor.Aggregate) {
            guard !members.isEmpty else { return }
            let id = members.count == 1 ? members[0] : SensorID(rawValue: "curated:\(key)")
            result.append(CuratedSensor(id: id, name: name, section: section, members: members, aggregate: aggregate))
        }
        let performance = ids(.cpuPerformance)
        let efficiency = ids(.cpuEfficiency)
        add("cpu.performance", "Performance cores, average", .cpuPerformance, performance, .average)
        add("cpu.performance.max", "Performance cores, hottest", .cpuPerformance, performance, .maximum)
        add("cpu.efficiency", "Efficiency cores, average", .cpuEfficiency, efficiency, .average)
        add("cpu.efficiency.max", "Efficiency cores, hottest", .cpuEfficiency, efficiency, .maximum)
        add("gpu", "GPU, average", .gpu, ids(.gpu), .average)
        add("gpu.max", "GPU, hottest", .gpu, ids(.gpu), .maximum)
        add("soc", "SoC die, average", .soc, ids(.soc) { $0.name.hasPrefix("PMU tdie") }, .average)
        add("ssd", "SSD", .ssd, ids(.ssd), .maximum)
        add("battery", "Battery", .battery, ids(.battery) { $0.id == .smc("TB0T") }, .maximum)
        return result
    }
}
