import Foundation

/// Everything one tick produced. A nil field was not sampled on this tick.
public struct SampleBatch: Sendable {
    public var cpu: CPUSnapshot?
    public var memory: MemorySnapshot?
    public var gpu: GPUSnapshot?
    public var temperatures: [SensorReading]?
    public var temperaturesAreFull = false
    public var temperatureSummary: TemperatureSummary?
    /// Sent once, with the first temperature batch.
    public var descriptors: [SensorDescriptor]?
    public var electrical: [SensorReading]?
    public var fans: [FanSnapshot]?
    public var battery: BatterySnapshot?
    public var frequency: FrequencySnapshot?
    public var livePower: LivePowerSnapshot?
    public var network: ThroughputSnapshot?
    public var disk: ThroughputSnapshot?
    public var processes: ProcessSnapshot?

    public init() {}
}

/// Hardware access for one engine. Anything absent on this Mac is nil, and its UI is hidden.
public struct HardwareReaders: Sendable {
    public var cpu: (any CPUReading)?
    public var memory: (any MemoryReading)?
    public var gpu: (any GPUReading)?
    public var sensors: (any SensorSampling)?
    public var fans: (any FanReading)?
    public var battery: (any BatteryReading)?
    public var frequency: (any FrequencyReading)?
    public var power: (any LivePowerReading)?
    public var network: (any ThroughputReading)?
    public var disk: (any ThroughputReading)?
    public var processes: (any ProcessReading)?

    public init(
        cpu: (any CPUReading)? = nil, memory: (any MemoryReading)? = nil, gpu: (any GPUReading)? = nil,
        sensors: (any SensorSampling)? = nil, fans: (any FanReading)? = nil, battery: (any BatteryReading)? = nil,
        frequency: (any FrequencyReading)? = nil
    ) {
        self.cpu = cpu
        self.memory = memory
        self.gpu = gpu
        self.sensors = sensors
        self.fans = fans
        self.battery = battery
        self.frequency = frequency
    }
}

public struct DemandToken: Hashable, Sendable {
    fileprivate let id: UInt64
}

/// The one sampling loop. Owns a single one-shot timer that exists only while something is demanded and the system is
/// awake. All reads happen here, serially, off the main thread.
public actor SamplingEngine {
    private let readers: HardwareReaders
    private let deliver: @Sendable (SampleBatch) -> Void
    private var plan = SamplePlan()
    private var demands: [UInt64: SampleDemand] = [:]
    private var ownedDemands: [String: [SampleDemand]] = [:]
    private var nextID: UInt64 = 0
    private var multiplier = 1.0
    private var paused = false
    private var timer: (any DispatchSourceTimer)?
    private var sensorGroups: [SensorID: SensorGroup]?
    private let timerQueue = DispatchQueue(label: "com.jmacostweaker.sampling.timer", qos: .utility)

    public init(readers: HardwareReaders, deliver: @escaping @Sendable (SampleBatch) -> Void) {
        self.readers = readers
        self.deliver = deliver
    }

    private var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    public func register(_ demand: SampleDemand) -> DemandToken {
        nextID += 1
        demands[nextID] = demand
        replan()
        return DemandToken(id: nextID)
    }

    public func remove(_ token: DemandToken) {
        demands[token.id] = nil
        replan()
    }

    /// Replaces everything one owner wants, for owners that recompute their whole demand at once.
    public func setDemands(owner: String, _ wanted: [SampleDemand]) {
        ownedDemands[owner] = wanted.isEmpty ? nil : wanted
        replan()
    }

    /// Stops all polling while the display or system sleeps.
    public func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        replan()
    }

    /// Slows every rate in Low Power Mode or under thermal pressure.
    public func setRateMultiplier(_ value: Double) {
        guard multiplier != value else { return }
        multiplier = value
        replan()
    }

    /// Reads a source right away, for example after a power source notification.
    public func expedite(_ source: SampleSource) {
        plan.expedite(source, now: now)
        rearm()
    }

    public var activeSources: Set<SampleSource> {
        Set(plan.intervals.keys)
    }

    private func replan() {
        let live = paused ? [] : Array(demands.values) + ownedDemands.values.flatMap { $0 }
        plan.update(demands: live, multiplier: multiplier, now: now)
        rearm()
    }

    private func rearm() {
        guard let fire = plan.nextFire else {
            timer?.cancel()
            timer = nil
            return
        }
        let delay = max(fire - now, 0)
        let leeway = max(plan.intervals.values.min() ?? 1, 0.1) * 0.1
        if let timer {
            timer.schedule(deadline: .now() + delay, leeway: .milliseconds(Int(leeway * 1000)))
            return
        }
        let source = DispatchSource.makeTimerSource(queue: timerQueue)
        source.schedule(deadline: .now() + delay, leeway: .milliseconds(Int(leeway * 1000)))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.tick() }
        }
        source.resume()
        timer = source
    }

    private func tick() {
        let due = plan.takeDue(now: now)
        rearm()
        guard !due.isEmpty else { return }
        let batch = read(due)
        deliver(batch)
    }

    private func read(_ due: Set<SampleSource>) -> SampleBatch {
        var batch = SampleBatch()
        if due.contains(.cpu) { batch.cpu = readers.cpu?.sample() }
        if due.contains(.memory) { batch.memory = readers.memory?.sample() }
        if due.contains(.gpu) { batch.gpu = readers.gpu?.sample() }
        if due.contains(.fans) { batch.fans = readers.fans?.sample() }
        if due.contains(.battery) { batch.battery = readers.battery?.sample() }
        if due.contains(.frequency) { batch.frequency = readers.frequency?.sample() }
        if due.contains(.power) { batch.livePower = readers.power?.sample() }
        if due.contains(.network) { batch.network = readers.network?.sample() }
        if due.contains(.disk) { batch.disk = readers.disk?.sample() }
        if due.contains(.processes) { batch.processes = readers.processes?.sample() }
        if due.contains(.temperatureFull) {
            batch.temperatures = readers.sensors?.sampleTemperatures(full: true)
            batch.temperaturesAreFull = true
        } else if due.contains(.temperatureSummary) {
            batch.temperatures = readers.sensors?.sampleTemperatures(full: false)
        }
        if let readings = batch.temperatures {
            if sensorGroups == nil, let descriptors = readers.sensors?.descriptors() {
                sensorGroups = Dictionary(descriptors.map { ($0.id, $0.group) }, uniquingKeysWith: { first, _ in first })
                batch.descriptors = descriptors
            }
            let groups = sensorGroups ?? [:]
            batch.temperatureSummary = TemperatureSummary.make(readings: readings) { groups[$0] }
        }
        if due.contains(.electrical) { batch.electrical = readers.sensors?.sampleElectrical() }
        return batch
    }
}
