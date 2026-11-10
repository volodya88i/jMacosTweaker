import Core
import Foundation
import Observation

enum ValueLevel: Sendable {
    case normal, warning, critical
}

/// Fixed-size history for one metric, in the metric's own unit.
typealias History = RingBuffer<Float>

/// One small observable per module, so an update only redraws the views that read that module.
@MainActor @Observable
final class CPUModel {
    var current: CPUSnapshot?
    var history = History(capacity: 120, filler: 0)

    func apply(_ snapshot: CPUSnapshot) {
        current = snapshot
        history.append(Float(snapshot.usage * 100))
    }
}

@MainActor @Observable
final class MemoryModel {
    var current: MemorySnapshot?
    var history = History(capacity: 120, filler: 0)

    func apply(_ snapshot: MemorySnapshot) {
        current = snapshot
        history.append(Float(snapshot.usage * 100))
    }
}

@MainActor @Observable
final class GPUModel {
    var current: GPUSnapshot?
    var history = History(capacity: 120, filler: 0)

    func apply(_ snapshot: GPUSnapshot) {
        current = snapshot
        history.append(Float(snapshot.device * 100))
    }
}

@MainActor @Observable
final class FrequencyModel {
    var current: FrequencySnapshot?
}

@MainActor @Observable
final class FansModel {
    var current: [FanSnapshot] = []
    var history = History(capacity: 120, filler: 0)

    var averageRPM: Double? {
        current.isEmpty ? nil : current.reduce(0) { $0 + $1.actualRPM } / Double(current.count)
    }

    func apply(_ snapshot: [FanSnapshot]) {
        current = snapshot
        if let averageRPM { history.append(Float(averageRPM)) }
    }
}

@MainActor @Observable
final class BatteryModel {
    var current: BatterySnapshot?
    var powerHistory = History(capacity: 120, filler: 0)
    private var live: LivePowerSnapshot?
    private var liveAt: TimeInterval = 0
    private var isLiveFresh: Bool { ProcessInfo.processInfo.systemUptime - liveAt < 15 }

    /// Live SMC figures while something asks for them, otherwise battery telemetry, which refreshes about every 35 s.
    var flow: PowerFlow? {
        if let flow = live?.flow, isLiveFresh { return flow }
        return current?.flow
    }

    func apply(_ snapshot: BatterySnapshot) {
        current = snapshot
        if flow == snapshot.flow, let watts = snapshot.systemWatts { powerHistory.append(Float(watts)) }
    }

    func apply(live value: LivePowerSnapshot) {
        live = value
        liveAt = ProcessInfo.processInfo.systemUptime
        if let watts = value.flow?.systemWatts { powerHistory.append(Float(watts)) }
    }

    var accessories: [AccessoryPower] { isLiveFresh ? live?.accessories ?? [] : [] }
    var macWatts: Double? { isLiveFresh ? live?.macWatts : nil }
}

@MainActor @Observable
final class ThroughputModel {
    var current: ThroughputSnapshot?
    var history = History(capacity: 120, filler: 0)

    func apply(_ snapshot: ThroughputSnapshot) {
        current = snapshot
        history.append(Float(snapshot.total))
    }
}

@MainActor @Observable
final class ProcessModel {
    var current: ProcessSnapshot?
}

/// The parts of the Mac that summaries and charts name.
enum TemperatureArea: String, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, ssd, battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: String(localized: "CPU")
        case .gpu: String(localized: "GPU")
        case .ssd: String(localized: "SSD")
        case .battery: String(localized: "Battery")
        }
    }

    func value(in summary: TemperatureSummary) -> Double? {
        switch self {
        case .cpu: summary.cpuHottest
        case .gpu: summary.gpu
        case .ssd: summary.ssd
        case .battery: summary.battery
        }
    }
}

struct SensorStats: Sendable {
    var latest: Double
    var minimum: Double
    var maximum: Double
    var sum: Double
    var count: Int
    var lastSeen: TimeInterval

    var average: Double { sum / Double(max(count, 1)) }
}

@MainActor @Observable
final class SensorsModel {
    /// Sensors that disappear for this long show as lost rather than as their last value.
    static let staleAfter: TimeInterval = 60

    var descriptors: [SensorDescriptor] = []
    var summary: TemperatureSummary?
    var stats: [SensorID: SensorStats] = [:]
    var temperatureHistory = History(capacity: 120, filler: 0)
    /// Per-area histories for the temperature chart. NaN marks a sample where that area had no reading.
    var areaHistory: [TemperatureArea: History] = [:]
    var curated: [CuratedSensor] = []

    func recordSummary(_ summary: TemperatureSummary) {
        self.summary = summary
        if let hottest = summary.hottest { temperatureHistory.append(Float(hottest)) }
        for area in TemperatureArea.allCases {
            let value = area.value(in: summary).map(Float.init) ?? .nan
            guard !value.isNaN || areaHistory[area] != nil else { continue }
            areaHistory[area, default: History(capacity: 120, filler: .nan)].append(value)
        }
    }

    private func group(of id: SensorID) -> SensorGroup? {
        curated.first { $0.id == id }?.section ?? descriptors.first { $0.id == id }?.group
    }

    /// True if the lighter summary read covers this sensor, or unknown until sensors have been listed.
    func isInSummary(_ id: SensorID) -> Bool {
        guard let group = group(of: id) else { return false }
        return group.isCPU || group == .gpu || group == .ssd || group == .battery
    }

    func shortLabel(for id: SensorID) -> String? {
        switch group(of: id) {
        case .cpuPerformance: "P-CPU"
        case .cpuEfficiency: "E-CPU"
        case .gpu: "GPU"
        case .soc: "SOC"
        case .ssd: "SSD"
        case .battery: "BAT"
        default: nil
        }
    }

    /// Builds the new statistics aside and assigns them once. Writing per sensor notified every row that reads
    /// statistics once per sensor: about 270 times 270 notifications every 2 s with all sensors shown.
    func apply(readings: [SensorReading], now: TimeInterval) {
        var updated = stats
        for reading in readings { Self.record(&updated, id: reading.id, value: reading.value, now: now) }
        Self.updateCurated(&updated, curated: curated, now: now)
        stats = updated
    }

    /// A new list arrives when sensors that were powered down at launch, such as the GPU's, report for the first time.
    /// Aggregates whose members changed start their statistics over, so they never mix two different sets of sensors.
    func replaceCatalog(_ value: [SensorDescriptor]) {
        let removed = Set(descriptors.map(\.id)).subtracting(value.map(\.id))
        let previous = Dictionary(curated.map { ($0.id, Set($0.members)) }, uniquingKeysWith: { first, _ in first })
        descriptors = value
        curated = SensorCuration.curated(from: value)
        for id in removed { stats[id] = nil }
        for sensor in curated where sensor.members.count > 1 && previous[sensor.id] != Set(sensor.members) {
            stats[sensor.id] = nil
        }
    }

    /// Starts min, max and average over from now.
    func resetStatistics() {
        stats.removeAll()
    }

    /// Aggregate rows get the same statistics as real sensors, computed only from sensors seen in this batch's window.
    private static func updateCurated(_ stats: inout [SensorID: SensorStats], curated: [CuratedSensor], now: TimeInterval) {
        guard !curated.isEmpty else { return }
        var values: [SensorID: Double] = [:]
        values.reserveCapacity(stats.count)
        for (id, entry) in stats where now - entry.lastSeen < 5 { values[id] = entry.latest }
        for sensor in curated where sensor.members.count > 1 {
            guard let value = sensor.value(from: values) else { continue }
            record(&stats, id: sensor.id, value: value, now: now)
        }
    }

    private static func record(_ stats: inout [SensorID: SensorStats], id: SensorID, value: Double, now: TimeInterval) {
        if var entry = stats[id] {
            entry.latest = value
            entry.minimum = min(entry.minimum, value)
            entry.maximum = max(entry.maximum, value)
            entry.sum += value
            entry.count += 1
            entry.lastSeen = now
            stats[id] = entry
        } else {
            stats[id] = SensorStats(latest: value, minimum: value, maximum: value, sum: value, count: 1, lastSeen: now)
        }
    }
}

/// Owns the sampling engine and the per-module models.
@MainActor
final class MonitorStore {
    let cpu = CPUModel()
    let memory = MemoryModel()
    let gpu = GPUModel()
    let frequency = FrequencyModel()
    let fans = FansModel()
    let battery = BatteryModel()
    let sensors = SensorsModel()
    let network = ThroughputModel()
    let disk = ThroughputModel()
    let processes = ProcessModel()

    let availability: Availability
    let engine: SamplingEngine
    /// Called after each batch, on the main actor. Menu bar widgets use this rather than observation.
    var onBatch: ((SampleBatch) -> Void)?

    struct Availability: Sendable {
        let hasGPU: Bool
        let hasFans: Bool
        let fanCount: Int
        let hasBattery: Bool
        let hasSensors: Bool

        func isAvailable(_ module: Module) -> Bool {
            switch module {
            case .cpu, .memory, .network, .disk: true
            case .gpu: hasGPU
            case .temperature: hasSensors
            case .fans: hasFans
            case .battery, .power: hasBattery
            }
        }
    }

    init(readers: HardwareReaders) {
        availability = Availability(
            hasGPU: readers.gpu != nil,
            hasFans: readers.fans != nil,
            fanCount: readers.fans?.fanCount ?? 0,
            hasBattery: readers.battery != nil,
            hasSensors: readers.sensors != nil
        )
        // The engine is created with a forwarding closure, because `self` is not ready until all stored properties are.
        let box = WeakStoreBox()
        engine = SamplingEngine(readers: readers) { batch in
            Task { @MainActor in box.store?.apply(batch) }
        }
        box.store = self
    }

    func apply(_ batch: SampleBatch) {
        if let value = batch.cpu { cpu.apply(value) }
        if let value = batch.memory { memory.apply(value) }
        if let value = batch.gpu { gpu.apply(value) }
        if let value = batch.frequency { frequency.current = value }
        if let value = batch.fans { fans.apply(value) }
        if let value = batch.battery { battery.apply(value) }
        if let value = batch.livePower { battery.apply(live: value) }
        if let value = batch.network { network.apply(value) }
        if let value = batch.disk { disk.apply(value) }
        if let value = batch.processes { processes.current = value }
        if let value = batch.descriptors { sensors.replaceCatalog(value) }
        if let value = batch.temperatureSummary { sensors.recordSummary(value) }
        let now = ProcessInfo.processInfo.systemUptime
        if let value = batch.temperatures { sensors.apply(readings: value, now: now) }
        if let value = batch.electrical { sensors.apply(readings: value, now: now) }
        onBatch?(batch)
    }
}

@MainActor
private final class WeakStoreBox: @unchecked Sendable {
    weak var store: MonitorStore?
}
