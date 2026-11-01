@testable import Core
import XCTest

final class SamplePlanTests: XCTestCase {
    func testNoDemandMeansNoTimer() {
        var plan = SamplePlan()
        plan.update(demands: [], multiplier: 1, now: 0)
        XCTAssertNil(plan.nextFire)
        XCTAssertTrue(plan.takeDue(now: 100).isEmpty)
    }

    func testFastestDemandWinsAndRemovalStopsPolling() {
        var plan = SamplePlan()
        let slow = SampleDemand(sources: [.cpu], interval: 5)
        let fast = SampleDemand(sources: [.cpu, .memory], interval: 1)
        plan.update(demands: [slow, fast], multiplier: 1, now: 0)
        XCTAssertEqual(plan.intervals[.cpu], 1)
        plan.update(demands: [slow], multiplier: 1, now: 1)
        XCTAssertEqual(plan.intervals[.cpu], 5)
        XCTAssertNil(plan.intervals[.memory], "a source nothing wants is never read")
    }

    func testCoalescesNearbySources() {
        var plan = SamplePlan(coalesceWindow: 0.25)
        plan.update(demands: [SampleDemand(sources: [.cpu], interval: 1), SampleDemand(sources: [.memory], interval: 1.1)], multiplier: 1, now: 0)
        XCTAssertEqual(plan.takeDue(now: 0), [.cpu, .memory])
        XCTAssertEqual(plan.takeDue(now: 1.0), [.cpu, .memory], "1.1 is inside the window of 1.0, so one wakeup serves both")
    }

    func testRepeatedTicksFollowInterval() {
        var plan = SamplePlan(coalesceWindow: 0)
        plan.update(demands: [SampleDemand(sources: [.gpu], interval: 2)], multiplier: 1, now: 0)
        XCTAssertEqual(plan.takeDue(now: 0), [.gpu])
        XCTAssertEqual(plan.nextFire, 2)
        XCTAssertTrue(plan.takeDue(now: 1).isEmpty)
        XCTAssertEqual(plan.takeDue(now: 2), [.gpu])
    }

    func testMultiplierSlowsRatesButNeverSpeedsUp() {
        var plan = SamplePlan()
        plan.update(demands: [SampleDemand(sources: [.cpu], interval: 5)], multiplier: 2, now: 0)
        XCTAssertEqual(plan.intervals[.cpu], 10)
        plan.update(demands: [SampleDemand(sources: [.cpu], interval: 5)], multiplier: 0.5, now: 0)
        XCTAssertEqual(plan.intervals[.cpu], 5)
    }

    func testOpeningDetailViewSamplesImmediately() {
        var plan = SamplePlan(coalesceWindow: 0)
        plan.update(demands: [SampleDemand(sources: [.cpu], interval: 5)], multiplier: 1, now: 0)
        _ = plan.takeDue(now: 0)
        plan.update(demands: [SampleDemand(sources: [.cpu], interval: 1)], multiplier: 1, now: 1)
        XCTAssertEqual(plan.takeDue(now: 1), [.cpu])
    }

    func testExpediteOnlyAffectsDemandedSources() {
        var plan = SamplePlan(coalesceWindow: 0)
        plan.update(demands: [SampleDemand(sources: [.battery], interval: 30)], multiplier: 1, now: 0)
        _ = plan.takeDue(now: 0)
        plan.expedite(.battery, now: 5)
        plan.expedite(.cpu, now: 5)
        XCTAssertEqual(plan.takeDue(now: 5), [.battery])
    }
}

final class RingBufferTests: XCTestCase {
    func testKeepsNewestInOrder() {
        var ring = RingBuffer(capacity: 3, filler: 0)
        XCTAssertNil(ring.last)
        [1, 2].forEach { ring.append($0) }
        XCTAssertEqual(ring.elements, [1, 2])
        [3, 4, 5].forEach { ring.append($0) }
        XCTAssertEqual(ring.elements, [3, 4, 5])
        XCTAssertEqual(ring.last, 5)
        XCTAssertEqual(ring.count, 3)
    }
}

final class LoadMathTests: XCTestCase {
    func testCPUDeltaWithClusters() throws {
        let old = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0), CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let new = [CPUTicks(user: 50, system: 25, idle: 25, nice: 0), CPUTicks(user: 0, system: 0, idle: 100, nice: 0)]
        let snapshot = try XCTUnwrap(CPULoadMath.snapshot(old: old, new: new, kinds: [.performance, .efficiency]))
        XCTAssertEqual(snapshot.usage, 0.375, accuracy: 0.001)
        XCTAssertEqual(snapshot.clusterUsage(.performance) ?? 0, 0.75, accuracy: 0.001)
        XCTAssertEqual(snapshot.clusterUsage(.efficiency) ?? 1, 0, accuracy: 0.001)
    }

    func testCPUCountersThatWrapStayValid() throws {
        let old = [CPUTicks(user: UInt64(UInt32.max), system: 0, idle: 0, nice: 0)]
        let new = [CPUTicks(user: 9, system: 0, idle: 10, nice: 0)]
        let snapshot = try XCTUnwrap(CPULoadMath.snapshot(old: old, new: new, kinds: []))
        XCTAssertEqual(snapshot.user, 0.5, accuracy: 0.001)
    }

    func testCPUEdgeCases() {
        XCTAssertNil(CPULoadMath.snapshot(old: [], new: [], kinds: []))
        let same = [CPUTicks(user: 1, system: 1, idle: 1, nice: 1)]
        XCTAssertNil(CPULoadMath.snapshot(old: same, new: same, kinds: []), "no elapsed ticks")
        XCTAssertNil(CPULoadMath.snapshot(old: same, new: same + same, kinds: []), "core count changed")
    }

    func testMemoryUsageDefinition() {
        let memory = MemorySnapshot(total: 100, app: 10, wired: 20, compressed: 30, cached: 5, free: 35, swapUsed: 0, pressure: .normal)
        XCTAssertEqual(memory.used, 60)
        XCTAssertEqual(memory.usage, 0.6, accuracy: 0.001)
    }

    func testGPUParse() throws {
        let parsed = try XCTUnwrap(GPUReader.parse(["Device Utilization %": 22, "Renderer Utilization %": 21]))
        XCTAssertEqual(parsed.device, 0.22, accuracy: 0.001)
        XCTAssertNil(parsed.tiler)
        XCTAssertNil(GPUReader.parse(["Device Utilization %": 400]))
        XCTAssertNil(GPUReader.parse([:]))
    }

    func testFrequencyTableFormats() {
        func entry(_ value: UInt32) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) } + Data(count: 4)
        }
        let table = FrequencyMath.decodeTable(entry(14524) + entry(1_578_000_000) + entry(0) + entry(1))
        XCTAssertEqual(table[0] ?? 0, 4512, accuracy: 1, "M4 Pro P core top state")
        XCTAssertEqual(table[1] ?? 0, 1578, accuracy: 1, "M4 Pro GPU top state")
        XCTAssertNil(table[2])
        XCTAssertNil(table[3], "implausible value")
    }

    func testFrequencyAverage() {
        XCTAssertEqual(FrequencyMath.average(residencies: [1, 3], table: [1000, 2000]) ?? 0, 1750, accuracy: 0.1)
        XCTAssertNil(FrequencyMath.average(residencies: [0, 0], table: [1000, 2000]), "idle")
        XCTAssertNil(FrequencyMath.average(residencies: [1], table: [1000, 2000]), "state count mismatch")
    }
}

final class PowerFlowTests: XCTestCase {
    private func flow(_ external: Bool, _ adapter: Double?, _ system: Double?, _ battery: Double?, loss: Double? = nil) -> PowerFlow {
        PowerFlowMath.reconcile(externalConnected: external, adapterWatts: adapter, systemWatts: system, batteryWatts: battery, lossWatts: loss)
    }

    func testOnBatteryObservedOnThisMac() {
        XCTAssertEqual(flow(false, 0, 8.102, -8.102), .onBattery(systemWatts: 8.102))
    }

    func testChargingSplit() {
        XCTAssertEqual(flow(true, 46, 18.4, 27.6), .adapterCharging(adapterWatts: 46, systemWatts: 18.4, batteryWatts: 27.6))
    }

    func testAdapterOnlyAtLimit() {
        XCTAssertEqual(flow(true, 20, 20, 0.1), .adapterOnly(adapterWatts: 20, systemWatts: 20))
    }

    func testBatteryAssistsWeakAdapter() {
        XCTAssertEqual(flow(true, 30, 45, -15), .batteryAssist(adapterWatts: 30, systemWatts: 45, batteryWatts: 15))
    }

    func testStaleTelemetryRightAfterPluggingInIsNotShown() {
        XCTAssertEqual(flow(true, 0, 5.98, -5.98), .inconsistent, "observed for about 30 s after plugging in")
    }

    func testObservedAdapterSamples() {
        XCTAssertEqual(flow(true, 86.2, 13.0, 73.2, loss: 2.6), .adapterCharging(adapterWatts: 86.2, systemWatts: 13.0, batteryWatts: 73.2))
        XCTAssertEqual(flow(true, 87.7, 23.2, 64.5, loss: 2.7), .adapterCharging(adapterWatts: 87.7, systemWatts: 23.2, batteryWatts: 64.5))
    }

    func testLossesAreAllowed() {
        XCTAssertEqual(flow(true, 50, 18, 25, loss: 7), .adapterCharging(adapterWatts: 50, systemWatts: 18, batteryWatts: 25))
    }

    func testNumbersThatDoNotAddUpAreNotShown() {
        XCTAssertEqual(flow(true, 100, 18, 25), .inconsistent)
        XCTAssertEqual(flow(false, 0, 50, -8), .inconsistent)
        XCTAssertEqual(flow(false, 0, 8, 8), .inconsistent, "cannot charge without an adapter")
    }

    func testMissingOrInsaneFieldsAreNotShown() {
        XCTAssertEqual(flow(true, nil, 18, 25), .inconsistent)
        XCTAssertEqual(flow(true, 46, nil, 25), .inconsistent)
        XCTAssertEqual(flow(true, 46, 18, nil), .inconsistent)
        XCTAssertEqual(flow(true, 46, .nan, 25), .inconsistent)
        XCTAssertEqual(flow(true, 46, -5, 25), .inconsistent)
        XCTAssertEqual(flow(true, 1e6, 18, 25), .inconsistent)
    }

    func testBatteryParseWithObservedShape() throws {
        let root: [String: Any] = [
            "BatteryInstalled": true, "CurrentCapacity": 46, "ExternalConnected": false, "IsCharging": false,
            "FullyCharged": false, "AvgTimeToEmpty": 211, "AvgTimeToFull": 65535, "CycleCount": 72, "Voltage": 11507,
            "InstantAmperage": -660, "AdapterDetails": ["FamilyCode": 0],
            "BatteryData": ["DesignCapacity": 6249, "FullChargeCapacity": 5672],
            "PowerTelemetryData": ["SystemLoad": 8102, "BatteryPower": -8102, "SystemPowerIn": 0, "AdapterEfficiencyLoss": 0]
        ]
        let battery = try XCTUnwrap(BatteryReader.parse(root, temperature: 26.8))
        XCTAssertEqual(battery.percent, 46)
        XCTAssertEqual(battery.state, .discharging)
        XCTAssertEqual(battery.minutesToEmpty, 211)
        XCTAssertNil(battery.minutesToFull, "65535 means no estimate")
        XCTAssertEqual(battery.health ?? 0, 0.908, accuracy: 0.001)
        XCTAssertEqual(battery.batteryWatts ?? 0, -7.59, accuracy: 0.01)
        XCTAssertEqual(battery.systemWatts ?? 0, 8.102, accuracy: 0.001)
        XCTAssertNil(battery.adapter)
    }

    func testBatteryParseRejectsGarbage() {
        XCTAssertNil(BatteryReader.parse([:], temperature: nil), "no battery installed")
        XCTAssertNil(BatteryReader.parse(["BatteryInstalled": true, "CurrentCapacity": 900], temperature: nil))
        let hot = BatteryReader.parse(["BatteryInstalled": true, "CurrentCapacity": 50], temperature: -9200)
        XCTAssertNil(hot?.temperature)
        XCTAssertEqual(hot?.flow, .inconsistent)
    }
}

final class SensorCatalogTests: XCTestCase {
    func testGroupsFromCorrelation() {
        XCTAssertEqual(SensorCatalog.group(smcKey: "Tp1a"), .cpuPerformance)
        XCTAssertEqual(SensorCatalog.group(smcKey: "Tp2G"), .cpuPerformance)
        XCTAssertEqual(SensorCatalog.group(smcKey: "Te05"), .cpuEfficiency)
        XCTAssertEqual(SensorCatalog.group(smcKey: "Tg0f"), .gpu)
        XCTAssertEqual(SensorCatalog.group(smcKey: "TB0T"), .battery)
        XCTAssertEqual(SensorCatalog.group(hidName: "NAND CH0 temp"), .ssd)
    }

    func testAggregateKeysAreNotListed() {
        XCTAssertFalse(SensorCatalog.isListedTemperatureKey("Tpx0"))
        XCTAssertFalse(SensorCatalog.isListedTemperatureKey("FNum"))
        XCTAssertTrue(SensorCatalog.isListedTemperatureKey("Tp1a"))
    }

    func testPlausibilityRejectsGarbageSeenOnThisMac() {
        XCTAssertFalse(SensorCatalog.isPlausible(-9200, kind: .temperature))
        XCTAssertFalse(SensorCatalog.isPlausible(.nan, kind: .temperature))
        XCTAssertFalse(SensorCatalog.isPlausible(0, kind: .temperature))
        XCTAssertFalse(SensorCatalog.isPlausible(500, kind: .temperature))
        XCTAssertTrue(SensorCatalog.isPlausible(42, kind: .temperature))
        XCTAssertTrue(SensorCatalog.isPlausible(-0.6, kind: .current))
    }

    func testSummary() {
        let groups: [SensorID: SensorGroup] = [
            .smc("Tp1a"): .cpuPerformance, .smc("Te05"): .cpuEfficiency, .smc("Tg0f"): .gpu, .smc("TB0T"): .battery
        ]
        let readings = [
            SensorReading(id: .smc("Tp1a"), value: 60), SensorReading(id: .smc("Te05"), value: 40),
            SensorReading(id: .smc("Tg0f"), value: 70), SensorReading(id: .smc("TB0T"), value: 30)
        ]
        let summary = TemperatureSummary.make(readings: readings) { groups[$0] }
        XCTAssertEqual(summary.cpuHottest, 60)
        XCTAssertEqual(summary.cpuAverage, 50)
        XCTAssertEqual(summary.hottest, 70)
        XCTAssertNil(summary.ssd)
    }
}

/// Fake reader that counts calls.
private final class CountingCPU: CPUReading, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func sample() -> CPUSnapshot? {
        lock.withLock { calls += 1 }
        return CPUSnapshot(user: 0.1, system: 0.1, idle: 0.8, cores: [])
    }
}

final class SamplingEngineTests: XCTestCase {
    func testPollingFollowsDemand() async throws {
        let cpu = CountingCPU()
        let engine = SamplingEngine(readers: HardwareReaders(cpu: cpu)) { _ in }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(cpu.count, 0, "no demand means no reads")

        let token = await engine.register(SampleDemand(sources: [.cpu], interval: 0.05))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(cpu.count, 1)

        await engine.remove(token)
        let stopped = cpu.count
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertLessThanOrEqual(cpu.count, stopped + 1, "reads stop once demand goes away")
    }

    func testPauseStopsPolling() async throws {
        let cpu = CountingCPU()
        let engine = SamplingEngine(readers: HardwareReaders(cpu: cpu)) { _ in }
        _ = await engine.register(SampleDemand(sources: [.cpu], interval: 0.05))
        await engine.setPaused(true)
        try await Task.sleep(for: .milliseconds(50))
        let paused = cpu.count
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertLessThanOrEqual(cpu.count, paused + 1)
        await engine.setPaused(false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(cpu.count, paused)
    }
}
