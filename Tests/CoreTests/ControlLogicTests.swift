@testable import Core
import Shared
import XCTest

final class CurveTests: XCTestCase {
    private let curve = FanCurve(points: [.init(temperature: 40, percent: 0), .init(temperature: 60, percent: 50), .init(temperature: 80, percent: 100)])

    func testInterpolation() {
        XCTAssertEqual(CurveMath.percent(at: 20, curve: curve), 0)
        XCTAssertEqual(CurveMath.percent(at: 40, curve: curve), 0)
        XCTAssertEqual(CurveMath.percent(at: 50, curve: curve), 25)
        XCTAssertEqual(CurveMath.percent(at: 70, curve: curve), 75)
        XCTAssertEqual(CurveMath.percent(at: 200, curve: curve), 100)
        XCTAssertEqual(CurveMath.percent(at: 50, curve: FanCurve(points: [])), 100, "an empty curve fails toward cooling")
    }

    func testValidation() {
        func result(_ points: [CurvePoint]) -> CurveError? {
            if case let .failure(error) = CurveMath.validate(FanCurve(points: points)) { return error }
            return nil
        }
        XCTAssertNil(result(curve.points))
        XCTAssertEqual(result([.init(temperature: 40, percent: 0)]), .tooFewPoints)
        XCTAssertEqual(result([.init(temperature: 60, percent: 0), .init(temperature: 40, percent: 10)]), .notIncreasing)
        XCTAssertEqual(result([.init(temperature: 40, percent: 0), .init(temperature: 40, percent: 10)]), .notIncreasing)
        XCTAssertEqual(result([.init(temperature: 40, percent: 50), .init(temperature: 60, percent: 10)]), .notMonotonic)
        XCTAssertEqual(result([.init(temperature: 40, percent: -1), .init(temperature: 60, percent: 10)]), .percentOutOfRange)
        XCTAssertEqual(result([.init(temperature: 40, percent: 0), .init(temperature: 60, percent: 101)]), .percentOutOfRange)
        XCTAssertEqual(result([.init(temperature: .nan, percent: 0), .init(temperature: 60, percent: 10)]), .temperatureOutOfRange)
        XCTAssertEqual(result([.init(temperature: 40, percent: 0), .init(temperature: 500, percent: 10)]), .temperatureOutOfRange)
    }

    func testBuiltInPresetsAreValidAndReachFullSpeedBelowTheSupervisor() throws {
        for preset in [FanPreset.silent, .balanced, .performance] {
            let curve = try XCTUnwrap(preset.curve)
            XCTAssertNoThrow(try CurveMath.validate(curve).get())
            XCTAssertEqual(CurveMath.percent(at: 90, curve: curve), 100, "\(preset)")
        }
    }
}

final class RampTests: XCTestCase {
    private func target(_ temperature: Double) -> Double { temperature * 50 }

    func testRampUpIsRateLimited() {
        var tuning = FanRamp.Tuning()
        tuning.smoothing = 1
        var ramp = FanRamp(tuning: tuning)
        XCTAssertEqual(ramp.step(temperature: 40, now: 0, target: target), 2000)
        XCTAssertEqual(ramp.step(temperature: 90, now: 1, target: target), 2000 + tuning.rampUpPerSecond)
    }

    func testFallIsSlowerThanRise() {
        var tuning = FanRamp.Tuning()
        tuning.smoothing = 1
        tuning.dwell = 0
        var ramp = FanRamp(tuning: tuning)
        _ = ramp.step(temperature: 80, now: 0, target: target)
        XCTAssertEqual(ramp.step(temperature: 40, now: 1, target: target), 4000 - tuning.rampDownPerSecond)
    }

    func testHysteresisStopsSmallDips() {
        var tuning = FanRamp.Tuning()
        tuning.smoothing = 1
        var ramp = FanRamp(tuning: tuning)
        _ = ramp.step(temperature: 60, now: 0, target: target)
        for second in 1...20 {
            XCTAssertNil(ramp.step(temperature: 59, now: TimeInterval(second), target: target))
        }
    }

    func testOscillatingTemperatureDoesNotHunt() {
        var ramp = FanRamp()
        var writes = 0
        _ = ramp.step(temperature: 60, now: 0, target: target)
        for second in 1...120 where ramp.step(temperature: second % 2 == 0 ? 59 : 61, now: TimeInterval(second), target: target) != nil {
            writes += 1
        }
        XCTAssertLessThanOrEqual(writes, 3, "a 2 °C wobble must not cause a stream of writes")
    }

    func testSmallChangesAreNotWritten() {
        var tuning = FanRamp.Tuning()
        tuning.smoothing = 1
        tuning.writeThreshold = 100
        var ramp = FanRamp(tuning: tuning)
        _ = ramp.step(temperature: 60, now: 0, target: target)
        XCTAssertEqual(ramp.step(temperature: 61, now: 10, target: target), 3050, "reaching the final target always lands")
        XCTAssertNil(ramp.step(temperature: 61, now: 20, target: target))
    }

    func testRiseIsNeverBlockedByDwell() {
        var tuning = FanRamp.Tuning()
        tuning.smoothing = 1
        tuning.dwell = 1000
        var ramp = FanRamp(tuning: tuning)
        _ = ramp.step(temperature: 80, now: 0, target: target)
        _ = ramp.step(temperature: 40, now: 1, target: target)
        XCTAssertNotNil(ramp.step(temperature: 95, now: 2, target: target), "cooling must never wait")
    }

    func testFallWaitsForDwellAfterARise() {
        var tuning = FanRamp.Tuning()
        tuning.smoothing = 1
        tuning.dwell = 10
        var ramp = FanRamp(tuning: tuning)
        _ = ramp.step(temperature: 50, now: 0, target: target)
        XCTAssertNotNil(ramp.step(temperature: 90, now: 1, target: target))
        XCTAssertNil(ramp.step(temperature: 40, now: 2, target: target))
        XCTAssertNotNil(ramp.step(temperature: 40, now: 20, target: target))
    }
}

final class PresetFileTests: XCTestCase {
    private let curve = FanCurve(points: [.init(temperature: 40, percent: 0), .init(temperature: 80, percent: 100)])

    func testRoundTrip() throws {
        let presets = [NamedPreset(name: "Quiet", curve: curve, sensor: .gpu)]
        XCTAssertEqual(try PresetFile.decode(PresetFile.encode(presets)).get(), presets)
    }

    func testMigratesSchema1() throws {
        let json = #"{"schema":1,"presets":[{"name":"Old","points":[{"temperature":40,"percent":0},{"temperature":80,"percent":100}]}]}"#
        let presets = try PresetFile.decode(Data(json.utf8)).get()
        XCTAssertEqual(presets, [NamedPreset(name: "Old", curve: curve, sensor: .hottest)])
    }

    func testRefusesNewerSchemaAndGarbage() {
        XCTAssertEqual(PresetFile.decode(Data(#"{"schema":99,"presets":[]}"#.utf8)), .failure(.newerSchema(99)))
        XCTAssertEqual(PresetFile.decode(Data("nonsense".utf8)), .failure(.malformed))
        XCTAssertEqual(PresetFile.decode(Data(#"{"schema":0}"#.utf8)), .failure(.malformed))
    }

    func testRefusesUnsafeCurve() {
        let json = #"{"schema":1,"presets":[{"name":"Bad","points":[{"temperature":80,"percent":0},{"temperature":40,"percent":100}]}]}"#
        XCTAssertEqual(PresetFile.decode(Data(json.utf8)), .failure(.invalidCurve("Bad")))
    }
}

final class ChargeMachineTests: XCTestCase {
    private func request(limit: Int = 80, sailing: Int = 5, heat: Bool = false, discharge: Bool = false, topUp: Bool = false, enabled: Bool = true) -> ChargeRequest {
        ChargeRequest(enabled: enabled, limit: limit, sailing: sailing, heatProtection: heat, heatLimit: 40, dischargeToLimit: discharge, topUp: topUp)
    }

    private func inputs(_ percent: Int?, temperature: Double? = 25, external: Bool = true) -> ChargeInputs {
        ChargeInputs(percent: percent, temperature: temperature, externalConnected: external)
    }

    func testDisabledAlwaysCharges() {
        var machine = ChargeStateMachine()
        XCTAssertEqual(machine.update(request: request(enabled: false), inputs: inputs(100)), .allowCharging)
    }

    func testSailingBandDoesNotFlap() {
        var machine = ChargeStateMachine()
        XCTAssertEqual(machine.update(request: request(), inputs: inputs(79)), .allowCharging)
        XCTAssertEqual(machine.update(request: request(), inputs: inputs(80)), .inhibitCharging)
        XCTAssertEqual(machine.update(request: request(), inputs: inputs(79)), .inhibitCharging)
        XCTAssertEqual(machine.update(request: request(), inputs: inputs(76)), .inhibitCharging)
        XCTAssertEqual(machine.update(request: request(), inputs: inputs(75)), .allowCharging)
        XCTAssertEqual(machine.update(request: request(), inputs: inputs(79)), .allowCharging)
    }

    // Invariant 8.
    func testNeverInhibitsAtOrBelowFloor() {
        var machine = ChargeStateMachine()
        _ = machine.update(request: request(), inputs: inputs(90))
        XCTAssertEqual(machine.update(request: request(heat: true), inputs: inputs(20, temperature: 80)), .allowCharging)
        XCTAssertEqual(machine.update(request: request(discharge: true), inputs: inputs(5)), .allowCharging)
    }

    func testUnreadableStateEnablesCharging() {
        var machine = ChargeStateMachine()
        _ = machine.update(request: request(), inputs: inputs(90))
        XCTAssertEqual(machine.update(request: request(), inputs: inputs(nil)), .allowCharging)
        XCTAssertEqual(machine.update(request: request(), inputs: inputs(900)), .allowCharging)
        XCTAssertEqual(machine.update(request: request(), inputs: inputs(-1)), .allowCharging)
    }

    func testHeatProtection() {
        var machine = ChargeStateMachine()
        XCTAssertEqual(machine.update(request: request(heat: true), inputs: inputs(50, temperature: 40)), .inhibitCharging)
        XCTAssertEqual(machine.update(request: request(heat: true), inputs: inputs(50, temperature: 38)), .inhibitCharging, "recovery band")
        XCTAssertEqual(machine.update(request: request(heat: true), inputs: inputs(50, temperature: 37)), .allowCharging)
        XCTAssertEqual(machine.update(request: request(heat: false), inputs: inputs(50, temperature: 60)), .allowCharging)
    }

    func testTopUpOverridesLimitThenFinishes() {
        var machine = ChargeStateMachine()
        XCTAssertEqual(machine.update(request: request(topUp: true), inputs: inputs(90)), .allowCharging)
        XCTAssertFalse(machine.topUpFinished)
        XCTAssertEqual(machine.update(request: request(topUp: true), inputs: inputs(100)), .allowCharging)
        XCTAssertTrue(machine.topUpFinished)
    }

    func testDischargeStopsAtLimitNotBelow() {
        var machine = ChargeStateMachine()
        XCTAssertEqual(machine.update(request: request(discharge: true), inputs: inputs(90)), .dischargeOnAdapter)
        XCTAssertEqual(machine.update(request: request(discharge: true), inputs: inputs(81)), .dischargeOnAdapter)
        XCTAssertEqual(machine.update(request: request(discharge: true), inputs: inputs(80)), .inhibitCharging)
        XCTAssertEqual(machine.update(request: request(discharge: true), inputs: inputs(90, external: false)), .inhibitCharging, "already on battery")
    }

    func testRequestsAreClamped() {
        let clamped = ChargeStateMachine.clamped(request(limit: 5, sailing: 99))
        XCTAssertEqual(clamped.limit, 50)
        XCTAssertEqual(clamped.sailing, 20)
        XCTAssertEqual(ChargeStateMachine.clamped(request(limit: 500)).limit, 100)
    }
}

final class ConflictTests: XCTestCase {
    private let fanTool = KnownTool(name: "Fan tool", label: "a", controls: [.fans])
    private let batteryTool = KnownTool(name: "Battery tool", label: "b", controls: [.charging])

    func testRunningWriterBlocksItsAreaOnly() {
        let conflicts = ConflictDetector.detect(tools: [fanTool, batteryTool], isInstalled: { _ in true }, isRunning: { $0 == "a" })
        XCTAssertEqual(ConflictDetector.blocker(in: conflicts, area: .fans), fanTool)
        XCTAssertNil(ConflictDetector.blocker(in: conflicts, area: .charging), "installed but idle is only a notice")
        XCTAssertEqual(conflicts.count, 2)
    }

    func testNothingFound() {
        XCTAssertTrue(ConflictDetector.detect(tools: [fanTool], isInstalled: { _ in false }, isRunning: { _ in false }).isEmpty)
    }
}

final class SensorCurationTests: XCTestCase {
    private func temperature(_ id: SensorID, _ name: String, _ group: SensorGroup) -> SensorDescriptor {
        SensorDescriptor(id: id, name: name, group: group, kind: .temperature)
    }

    func testAggregatesAndHidesRawSensors() throws {
        let curated = SensorCuration.curated(from: [
            temperature(.smc("Tp1a"), "CPU P cluster Tp1a", .cpuPerformance),
            temperature(.smc("Tp1b"), "CPU P cluster Tp1b", .cpuPerformance),
            temperature(.smc("TB0T"), "Battery TB0T", .battery),
            temperature(.smc("TB1T"), "Battery TB1T", .battery),
            temperature(.smc("Ts0a"), "SoC Ts0a", .soc)
        ])
        XCTAssertEqual(curated.map(\.name), ["Performance cores, average", "Performance cores, hottest", "Battery"])
        let values: [SensorID: Double] = [.smc("Tp1a"): 40, .smc("Tp1b"): 60]
        XCTAssertEqual(curated[0].value(from: values), 50)
        XCTAssertEqual(curated[1].value(from: values), 60)
        XCTAssertNil(curated[2].value(from: values), "a sensor with no reading has no value")
        XCTAssertEqual(curated[2].id, .smc("TB0T"), "a single sensor keeps its own identity")
    }

    func testDieSensorsStayOutOfTheShortList() throws {
        let curated = SensorCuration.curated(from: [
            temperature(.hid(.temperature, identity: "PMU tdie3#0"), "PMU tdie3", .soc),
            temperature(.hid(.temperature, identity: "PMU tdie3#1"), "PMU tdie3 (2)", .soc)
        ])
        XCTAssertEqual(curated.map(\.name), ["SoC die, average"])
    }

    func testNothingFoundMeansNoRows() {
        XCTAssertTrue(SensorCuration.curated(from: []).isEmpty)
    }

    func testOtherKindsAreIgnored() {
        let voltage = SensorDescriptor(id: .smc("VP0R"), name: "V", group: .cpuPerformance, kind: .voltage)
        XCTAssertTrue(SensorCuration.curated(from: [voltage]).isEmpty)
    }
}

private final class MockNativeLimit: NativeChargeLimitControlling, @unchecked Sendable {
    var limits = [80, 85, 90, 95, 100]
    var current: Int? = 80
    var acceptsWrites = true
    var appliesWrites = true
    var setCalls: [Int] = []

    func availableLimits() -> [Int] { limits }
    func currentLimit() -> Int? { current }
    func setLimit(_ value: Int) -> Bool {
        setCalls.append(value)
        if acceptsWrites, appliesWrites { current = value }
        return acceptsWrites
    }
}

final class NativeChargeLimitTests: XCTestCase {
    func testAppliesAndConfirmsAListedValue() {
        let control = MockNativeLimit()
        XCTAssertEqual(NativeChargeLimit.apply(85, using: control), .success(85))
        XCTAssertEqual(control.current, 85)
    }

    func testRefusesValuesMacOSDoesNotList() {
        let control = MockNativeLimit()
        XCTAssertEqual(NativeChargeLimit.apply(50, using: control), .failure(.notAccepted))
        XCTAssertEqual(NativeChargeLimit.apply(0, using: control), .failure(.notAccepted))
        XCTAssertEqual(NativeChargeLimit.apply(101, using: control), .failure(.notAccepted))
        XCTAssertTrue(control.setCalls.isEmpty, "nothing unlisted ever reaches macOS")
    }

    func testReportsRefusalAndAWriteThatDidNotApply() {
        let refused = MockNativeLimit()
        refused.acceptsWrites = false
        XCTAssertEqual(NativeChargeLimit.apply(85, using: refused), .failure(.refused))
        let ignored = MockNativeLimit()
        ignored.appliesWrites = false
        XCTAssertEqual(NativeChargeLimit.apply(85, using: ignored), .failure(.didNotApply))
    }

    func testNothingListedMeansNothingIsSet() {
        let control = MockNativeLimit()
        control.limits = []
        XCTAssertEqual(NativeChargeLimit.apply(80, using: control), .failure(.notAccepted))
    }
}

final class LivePowerTests: XCTestCase {
    func testOnBattery() {
        XCTAssertEqual(LivePowerMath.flow(adapterPresent: false, adapterWatts: 0, batteryVolts: 12, batteryAmps: -0.5), .onBattery(systemWatts: 6))
    }

    // Found on real hardware: PDTR read 6 to 7 W on battery with a phone charging from the Mac.
    func testAdapterKeyAloneDoesNotMeanAnAdapter() {
        XCTAssertEqual(LivePowerMath.flow(adapterPresent: false, adapterWatts: 6.5, batteryVolts: 12, batteryAmps: -1.5), .onBattery(systemWatts: 18))
    }

    func testChargingAddsUp() {
        XCTAssertEqual(LivePowerMath.flow(adapterPresent: true, adapterWatts: 86, batteryVolts: 12, batteryAmps: 6), .adapterCharging(adapterWatts: 86, systemWatts: 14, batteryWatts: 72))
    }

    func testHoldingAtLimitRunsFromAdapter() {
        XCTAssertEqual(LivePowerMath.flow(adapterPresent: true, adapterWatts: 7, batteryVolts: 12.4, batteryAmps: 0), .adapterOnly(adapterWatts: 7, systemWatts: 7))
    }

    func testBatteryAssist() {
        XCTAssertEqual(LivePowerMath.flow(adapterPresent: true, adapterWatts: 30, batteryVolts: 12, batteryAmps: -1), .batteryAssist(adapterWatts: 30, systemWatts: 42, batteryWatts: 12))
    }

    func testGarbageGivesNothing() {
        XCTAssertNil(LivePowerMath.flow(adapterPresent: true, adapterWatts: .nan, batteryVolts: 12, batteryAmps: 1))
        XCTAssertNil(LivePowerMath.flow(adapterPresent: true, adapterWatts: 5, batteryVolts: 0, batteryAmps: 1))
        XCTAssertNil(LivePowerMath.flow(adapterPresent: true, adapterWatts: 5, batteryVolts: 12, batteryAmps: 900))
        XCTAssertNil(LivePowerMath.flow(adapterPresent: true, adapterWatts: 5, batteryVolts: 12, batteryAmps: 2), "the system cannot draw negative power")
        XCTAssertNil(LivePowerMath.flow(adapterPresent: false, adapterWatts: 0, batteryVolts: 12, batteryAmps: 1), "charging with no adapter")
    }

    func testObservedPhone() throws {
        let phone = try XCTUnwrap(LivePowerMath.accessory(port: 3, isSourcing: true, volts: 5.2106, amps: 2.2033, name: "iPhone"))
        XCTAssertEqual(phone.watts, 11.48, accuracy: 0.01)
    }

    func testAccessoryPlausibility() {
        XCTAssertNil(LivePowerMath.accessory(port: 4, isSourcing: false, volts: 20, amps: 4, name: nil), "an adapter feeding the Mac is not an accessory")
        XCTAssertNil(LivePowerMath.accessory(port: 1, isSourcing: true, volts: 0, amps: 0, name: nil), "nothing connected")
        XCTAssertNil(LivePowerMath.accessory(port: 1, isSourcing: true, volts: .nan, amps: 1, name: nil))
        XCTAssertNil(LivePowerMath.accessory(port: 1, isSourcing: true, volts: 5, amps: 500, name: nil))
    }

    func testMacShareExcludesAccessories() throws {
        let phone = try XCTUnwrap(LivePowerMath.accessory(port: 3, isSourcing: true, volts: 5, amps: 2, name: nil))
        let snapshot = LivePowerSnapshot(flow: .onBattery(systemWatts: 16), accessories: [phone])
        XCTAssertEqual(snapshot.macWatts ?? 0, 6, accuracy: 0.001)
        XCTAssertEqual(LivePowerSnapshot(flow: .onBattery(systemWatts: 5), accessories: [phone]).macWatts, 0, "never negative")
        XCTAssertNil(LivePowerSnapshot(flow: .inconsistent, accessories: [phone]).macWatts)
    }

    func testMinutesToLimit() {
        XCTAssertEqual(LivePowerMath.minutesToLimit(percent: 50, limit: 80, fullCapacityMilliampHours: 5000, volts: 12, batteryWatts: 36), 30)
        XCTAssertNil(LivePowerMath.minutesToLimit(percent: 80, limit: 80, fullCapacityMilliampHours: 5000, volts: 12, batteryWatts: 36), "already there")
        XCTAssertNil(LivePowerMath.minutesToLimit(percent: 50, limit: 80, fullCapacityMilliampHours: 5000, volts: 12, batteryWatts: 0), "not charging")
        XCTAssertNil(LivePowerMath.minutesToLimit(percent: 50, limit: 80, fullCapacityMilliampHours: nil, volts: 12, batteryWatts: 36))
    }
}

final class ThroughputTests: XCTestCase {
    func testRate() {
        XCTAssertEqual(ThroughputMath.rate(new: 2000, old: 1000, seconds: 2), 500)
        XCTAssertEqual(ThroughputMath.rate(new: 500, old: 1000, seconds: 2), 0, "a removed disk is not negative traffic")
        XCTAssertEqual(ThroughputMath.rate(new: 2000, old: 1000, seconds: 0), 0)
    }

    func testNetworkCounterWrap() {
        XCTAssertEqual(ThroughputMath.wrappedDelta(new: 10, old: UInt32.max), 11)
        XCTAssertEqual(ThroughputMath.wrappedDelta(new: 100, old: 40), 60)
    }

    func testOnlyRealInterfacesCount() {
        XCTAssertTrue(ThroughputMath.isCountedInterface("en0"))
        for name in ["lo0", "utun3", "awdl0", "llw0", "bridge0", "anpi0"] {
            XCTAssertFalse(ThroughputMath.isCountedInterface(name), name)
        }
    }

    func testRealReadersRunOnThisMac() {
        let network = NetworkReader()
        _ = network.sample()
        XCTAssertNotNil(network.sample())
        let disk = DiskReader()
        _ = disk.sample()
        XCTAssertNotNil(disk.sample())
    }
}

final class ProcessTests: XCTestCase {
    func testCPUMath() {
        XCTAssertEqual(ProcessMath.cpu(newTime: 3_000_000_000, oldTime: 1_000_000_000, elapsedSeconds: 2, nanosecondsPerTick: 1), 1, accuracy: 0.001)
        XCTAssertEqual(ProcessMath.cpu(newTime: 24, oldTime: 0, elapsedSeconds: 1, nanosecondsPerTick: 41.67), 1e-6, accuracy: 1e-6)
        XCTAssertEqual(ProcessMath.cpu(newTime: 5, oldTime: 100, elapsedSeconds: 1, nanosecondsPerTick: 1), 0, "PID reused")
    }

    func testRanking() {
        let all = [ProcessUsage(pid: 1, name: "a", cpu: 0.1, memory: 300), ProcessUsage(pid: 2, name: "b", cpu: 0.9, memory: 100), ProcessUsage(pid: 3, name: "c", cpu: 0.5, memory: 200)]
        let top = ProcessSnapshot.top(all, count: 2)
        XCTAssertEqual(top.byCPU.map(\.pid), [2, 3])
        XCTAssertEqual(top.byMemory.map(\.pid), [1, 3])
    }

    func testRealReaderSeesThisProcess() throws {
        let reader = ProcessReader()
        XCTAssertNil(reader.sample(), "needs two samples")
        Thread.sleep(forTimeInterval: 0.05)
        let snapshot = try XCTUnwrap(reader.sample())
        XCTAssertFalse(snapshot.byMemory.isEmpty)
    }
}

