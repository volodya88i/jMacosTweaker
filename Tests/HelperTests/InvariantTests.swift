import Core
@testable import HelperCore
import Shared
import XCTest

private func failure(_ result: Result<Void, ControlCore.RequestError>) -> ControlCore.RequestError? {
    if case let .failure(error) = result { return error }
    return nil
}

/// One test group per invariant in SAFETY.md, plus chaos tests of the failure paths.
final class WhitelistTests: XCTestCase {
    // Invariant 1 and 9.
    func testWhitelistAcceptsOnlyControlKeys() {
        for key: SMCKey in ["F0Md", "F1Tg", "F9Md", "Ftst", "CHIE"] { XCTAssertTrue(KeyWhitelist.contains(key), "\(key)") }
        for key: SMCKey in ["ACLC", "MBSE", "MBSW", "F0Mn", "F0Mx", "F0Ac", "TB0T", "#KEY", "FNum", "BCLM", "CH0B", "FaMd"] {
            XCTAssertFalse(KeyWhitelist.contains(key), "\(key)")
        }
    }

    func testEveryOperationMapsToWhitelistedKey() {
        let operations: [ControlWrite] = [.unlockFans(true), .fanMode(fan: 0, value: 1), .fanTarget(fan: 9, rpm: 1), .chargeInhibit(value: 1)]
        for operation in operations { XCTAssertTrue(KeyWhitelist.contains(operation.key)) }
    }

    func testFullScenarioTouchesOnlyWhitelistedKeys() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.start()
        _ = core.applyFans(allFans(.curve(balancedCurve)), now: 0)
        _ = core.applyCharge(ChargeRequest(enabled: true, limit: 50, sailing: 5, heatProtection: true, heatLimit: 40, dischargeToLimit: false, topUp: false), now: 0)
        for second in 1...30 {
            inputs.cpu = 50 + Double(second)
            core.tick(now: TimeInterval(second))
        }
        core.restoreDefaults()
        XCTAssertFalse(port.writes.isEmpty)
        for write in port.writes { XCTAssertTrue(KeyWhitelist.contains(write.key), "\(write.key)") }
    }
}

final class ValidationTests: XCTestCase {
    private let limits = [0: FanLimits(minimum: 2317, maximum: 7826)]

    func testRejectsBadRequests() {
        func check(_ policy: FanPolicy, fan: Int = 0) -> Bool {
            if case .failure = ControlCore.validate(FanRequest(policies: [fan: policy], sensor: .hottest), limits: limits) { return false }
            return true
        }
        XCTAssertFalse(check(.constant(percent: 101)))
        XCTAssertFalse(check(.constant(percent: -1)))
        XCTAssertFalse(check(.constant(percent: .nan)))
        XCTAssertFalse(check(.maximum, fan: 7), "unknown fan")
        XCTAssertFalse(check(.curve(FanCurve(points: []))))
        XCTAssertFalse(check(.curve(FanCurve(points: [.init(temperature: 80, percent: 100), .init(temperature: 40, percent: 0)]))))
        XCTAssertTrue(check(.curve(balancedCurve)))
    }

    func testUnavailableCapabilityRefusesAndWritesNothing() {
        let port = MockPort()
        let core = makeCore(port: port, fanCapability: .unavailable("no"), chargeCapability: .unavailable("no"))
        XCTAssertEqual(failure(core.applyFans(allFans(.maximum), now: 0)), .unavailable)
        XCTAssertEqual(failure(core.applyCharge(.off, now: 0)), .unavailable)
        core.tick(now: 1)
        XCTAssertTrue(port.writes.isEmpty)
    }
}

final class ClientVerifierTests: XCTestCase {
    private let pin = PinnedClient(cdhash: "419f9496a28fc8dba4e02737fea7926e22cdbf4d", path: "/Applications/jMacosTweaker.app/Contents/MacOS/jMacosTweaker")

    private func identity() -> ClientIdentity {
        ClientIdentity(cdhash: "419F9496A28FC8DBA4E02737FEA7926E22CDBF4D", path: pin.path, pathOwnedByRoot: true, pathWritableByOthers: false, hasHardenedRuntime: true, allowsDebugging: false)
    }

    // Invariant 2.
    func testAcceptsOnlyThePinnedClient() {
        XCTAssertNil(ClientVerifier.check(identity: identity(), pin: pin))
        XCTAssertEqual(ClientVerifier.check(identity: identity(), pin: nil), .noPin)
        XCTAssertEqual(ClientVerifier.check(identity: nil, pin: pin), .unreadableIdentity)
        var other = identity()
        other.cdhash = String(repeating: "f", count: 40)
        XCTAssertEqual(ClientVerifier.check(identity: other, pin: pin), .hashMismatch)
        other = identity()
        other.path = "/tmp/evil"
        XCTAssertEqual(ClientVerifier.check(identity: other, pin: pin), .pathMismatch)
        other = identity()
        other.pathOwnedByRoot = false
        XCTAssertEqual(ClientVerifier.check(identity: other, pin: pin), .pathNotRootOwned)
        other = identity()
        other.pathWritableByOthers = true
        XCTAssertEqual(ClientVerifier.check(identity: other, pin: pin), .pathWritable)
        other = identity()
        other.hasHardenedRuntime = false
        XCTAssertEqual(ClientVerifier.check(identity: other, pin: pin), .noHardenedRuntime)
        other = identity()
        other.allowsDebugging = true
        XCTAssertEqual(ClientVerifier.check(identity: other, pin: pin), .debuggable)
    }

    func testEmptyPinNeverMatches() {
        var value = identity()
        value.cdhash = ""
        XCTAssertEqual(ClientVerifier.check(identity: value, pin: PinnedClient(cdhash: "", path: pin.path)), .malformedPin)
    }

    /// The pin is placed inside a code signing requirement, so text that could close the quote must be refused.
    func testMalformedPinIsRefusedBeforeUse() {
        let injected = PinnedClient(cdhash: "00\" or anchor apple or cdhash H\"00", path: pin.path)
        XCTAssertEqual(ClientVerifier.check(identity: identity(), pin: injected), .malformedPin)
        XCTAssertEqual(ClientVerifier.check(identity: identity(), pin: PinnedClient(cdhash: "abc123", path: pin.path)), .malformedPin)
        XCTAssertEqual(ClientVerifier.check(identity: identity(), pin: PinnedClient(cdhash: pin.cdhash, path: "relative/path")), .malformedPin)
        XCTAssertTrue(ClientVerifier.isWellFormedHash(String(repeating: "a", count: 64)))
        XCTAssertFalse(ClientVerifier.isWellFormedHash(String(repeating: "g", count: 40)))
    }
}

final class FailSafeTests: XCTestCase {
    private func assertSystemControl(_ port: MockPort, mode: Double = 3, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(port.value(FanKeys.mode(0)), mode, file: file, line: line)
        XCTAssertEqual(port.value(FanKeys.mode(1)), mode, file: file, line: line)
        XCTAssertEqual(port.value(KeyWhitelist.unlock), 0, file: file, line: line)
    }

    private func controlled(port: MockPort, inputs: MockInputs = MockInputs(), journal: MemoryStore = MemoryStore()) -> ControlCore {
        let core = makeCore(port: port, inputs: inputs, journal: journal)
        core.start()
        core.clientConnected(now: 0)
        XCTAssertNil(failure(core.applyFans(allFans(.constant(percent: 50)), now: 0)))
        XCTAssertEqual(port.value(FanKeys.mode(0)), 1)
        return core
    }

    // Invariant 3: app quit, crash or SIGKILL all look like a disconnect.
    func testDisconnectReturnsFansAfterGrace() {
        let port = MockPort()
        let core = controlled(port: port)
        core.clientDisconnected(now: 10)
        core.tick(now: 12)
        XCTAssertEqual(port.value(FanKeys.mode(0)), 1, "still inside the grace period")
        core.tick(now: 15)
        assertSystemControl(port)
        XCTAssertNotNil(core.lastError)
    }

    func testReconnectInsideGraceKeepsControl() {
        let port = MockPort()
        let core = controlled(port: port)
        core.clientDisconnected(now: 10)
        core.clientConnected(now: 12)
        core.tick(now: 20)
        XCTAssertEqual(port.value(FanKeys.mode(0)), 1)
    }

    func testHungAppIsTreatedLikeADeadOne() {
        let port = MockPort()
        let core = controlled(port: port)
        core.heartbeat(now: 5)
        core.tick(now: 24)
        XCTAssertEqual(port.value(FanKeys.mode(0)), 1)
        core.tick(now: 25)
        assertSystemControl(port)
    }

    func testHelperCrashIsUndoneAtNextStart() {
        let port = MockPort()
        let journal = MemoryStore()
        _ = controlled(port: port, journal: journal)
        XCTAssertNotNil(journal.data, "journal exists while fans are manual")
        // A new process with the same on-disk journal, as after a crash or reboot.
        let next = makeCore(port: port, journal: journal)
        next.start()
        assertSystemControl(port)
        XCTAssertNil(journal.data)
    }

    // Found on real hardware: the helper took about 56 s to be ready at boot.
    func testStartupRestoreDoesNotNeedSensors() {
        let port = MockPort()
        let inputs = MockInputs()
        let journal = MemoryStore()
        let first = makeCore(port: port, inputs: inputs, journal: journal)
        first.clientConnected(now: 0)
        _ = first.applyFans(allFans(.constant(percent: 50)), now: 0)
        XCTAssertEqual(port.value(FanKeys.mode(0)), 1)

        let quiet = MockInputs()
        let next = makeCore(port: port, inputs: quiet, journal: journal)
        next.start()
        assertSystemControl(port)
        XCTAssertEqual(quiet.readingCalls, 0)
    }

    func testJournalIsWrittenBeforeTheFirstWrite() {
        let port = MockPort()
        let journal = MemoryStore()
        journal.failSaves = true
        let core = makeCore(port: port, journal: journal)
        _ = core.applyFans(allFans(.maximum), now: 0)
        XCTAssertTrue(port.writes.isEmpty, "no journal, no write")
        XCTAssertNotNil(core.lastError)
    }

    func testOriginalModeIsRestoredWhereThereIsNoUnlockKey() {
        let port = MockPort(mode: 2, withUnlock: false)
        let core = makeCore(port: port)
        _ = core.applyFans(allFans(.maximum), now: 0)
        core.restoreDefaults()
        XCTAssertEqual(port.value(FanKeys.mode(0)), 2)
        XCTAssertEqual(port.value(FanKeys.mode(1)), 2)
    }

    func testSleepReleasesFansAndWakeReevaluates() {
        let port = MockPort()
        let core = controlled(port: port)
        core.willSleep()
        assertSystemControl(port)
        XCTAssertFalse(core.needsTimer)
        core.tick(now: 100)
        assertSystemControl(port)
        core.didWake(now: 200)
        XCTAssertEqual(port.value(FanKeys.mode(0)), 1, "request is re-applied on wake")
    }

    func testSleepMidRampLeavesNothingBehind() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.curve(balancedCurve)), now: 0)
        inputs.cpu = 75
        core.heartbeat(now: 1)
        core.tick(now: 1)
        core.willSleep()
        assertSystemControl(port)
        XCTAssertEqual(core.status(protocolVersion: 1).fansUnderControl, [])
    }

    func testSensorDropoutReturnsToSystem() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.curve(balancedCurve)), now: 0)
        XCTAssertEqual(port.value(FanKeys.mode(0)), 1)
        inputs.cpu = nil
        core.heartbeat(now: 3)
        core.tick(now: 3)
        XCTAssertEqual(port.value(FanKeys.mode(0)), 1, "a brief gap holds the last value")
        core.heartbeat(now: 6)
        core.tick(now: 6)
        assertSystemControl(port)
        XCTAssertNotNil(core.lastError)
    }

    /// Constant needs no control sensor, but the supervisor still needs temperatures to protect anything.
    func testConstantSpeedReturnsToSystemWhenTemperaturesVanish() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.constant(percent: 0)), now: 0)
        XCTAssertEqual(port.value(FanKeys.mode(0)), 1)
        inputs.cpu = nil
        inputs.gpu = nil
        core.heartbeat(now: 3)
        core.tick(now: 3)
        XCTAssertEqual(port.value(FanKeys.mode(0)), 1, "a brief gap is tolerated")
        core.heartbeat(now: 6)
        core.tick(now: 6)
        assertSystemControl(port)
        XCTAssertNil(core.status(protocolVersion: 1).fanRequest)
        XCTAssertNotNil(core.lastError)
    }

    func testMaximumNeedsNoTemperatures() {
        let port = MockPort()
        let inputs = MockInputs()
        inputs.cpu = nil
        inputs.gpu = nil
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.maximum), now: 0)
        for second in 1...10 {
            core.heartbeat(now: TimeInterval(second))
            core.tick(now: TimeInterval(second))
        }
        XCTAssertEqual(port.value(FanKeys.target(0)), 7826)
        XCTAssertEqual(port.value(FanKeys.mode(0)), 1)
    }

    func testCurveWithNoReadingYetStaysUnderSystemControl() {
        let port = MockPort()
        let inputs = MockInputs()
        inputs.cpu = nil
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.curve(balancedCurve)), now: 0)
        XCTAssertFalse(port.writes.contains { $0.key == FanKeys.mode(0) }, "no manual mode without a target to command")
    }

    func testImplausibleSensorCountsAsDropout() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.curve(balancedCurve)), now: 0)
        inputs.cpu = -9200
        core.heartbeat(now: 6)
        core.tick(now: 6)
        assertSystemControl(port)
    }

    // Found on real hardware: the saved mode 3 is refused while unlocked, so hand-back must not depend on it.
    func testHandBackWorksWithObservedFirmware() {
        let port = MockPort(mode: 3)
        let core = controlled(port: port)
        core.clientDisconnected(now: 10)
        core.tick(now: 15)
        assertSystemControl(port, mode: 3)
        XCTAssertFalse(core.needsTimer)
    }

    func testFanThatCannotReturnGoesToMaximumNotStuckLow() {
        let port = MockPort()
        let core = controlled(port: port)
        XCTAssertEqual(port.value(FanKeys.target(0)), 5071.5)
        port.rejectKeys = [FanKeys.mode(0)]
        core.clientDisconnected(now: 10)
        for second in 15...30 { core.tick(now: TimeInterval(second)) }
        XCTAssertEqual(port.value(FanKeys.mode(0)), 1)
        XCTAssertEqual(port.value(FanKeys.target(0)), 7826, "never left low with nothing watching")
        XCTAssertNotNil(core.lastError)
        port.rejectKeys = []
        core.tick(now: 31)
        core.tick(now: 32)
        assertSystemControl(port)
    }

    // Found on real hardware: F1Md fell to 0 after unlocking while the helper believed it held the fan.
    func testFanTakenBackIsReasserted() {
        let port = MockPort()
        let core = controlled(port: port)
        port.externallySet(FanKeys.mode(1), 0)
        port.externallySet(FanKeys.target(1), 2502)
        core.heartbeat(now: 1)
        core.tick(now: 1)
        XCTAssertEqual(port.value(FanKeys.mode(1)), 1)
        XCTAssertEqual(port.value(FanKeys.target(1)), 5071.5)
        core.heartbeat(now: 2)
        core.tick(now: 2)
        XCTAssertEqual(port.value(FanKeys.mode(1)), 1)
        XCTAssertNil(core.lastError)
    }

    func testFanThatKeepsBeingTakenGivesUpAndReleasesAll() {
        let port = MockPort()
        let core = controlled(port: port)
        for second in 1...6 {
            port.externallySet(FanKeys.mode(1), 0)
            core.heartbeat(now: TimeInterval(second))
            core.tick(now: TimeInterval(second))
        }
        XCTAssertNotNil(core.lastError)
        assertSystemControl(port)
        port.clearWrites()
        core.heartbeat(now: 9)
        core.tick(now: 9)
        XCTAssertTrue(port.writes.isEmpty, "no write loop after giving up")
    }

    func testAllFanModesAreRecordedBeforeUnlocking() {
        let port = MockPort()
        let journal = MemoryStore()
        let core = makeCore(port: port, journal: journal)
        core.clientConnected(now: 0)
        _ = core.applyFans(FanRequest(policies: [0: .maximum, 1: .system], sensor: .hottest), now: 0)
        let saved = journal.load(RestoreJournal.self)
        XCTAssertEqual(saved?.originalFanModes[1], 3)
        core.restoreDefaults()
        assertSystemControl(port)
    }

    // Found on real hardware: a curve at a steady temperature did not retry manual mode, and failed after the window.
    func testCurveAtSteadyTemperatureEntersManualMode() {
        let port = MockPort()
        port.unlockDelayTicks = 6
        let core = makeCore(port: port)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.curve(balancedCurve)), now: 0)
        for second in 1...30 {
            port.firmwareTick()
            core.heartbeat(now: TimeInterval(second))
            core.tick(now: TimeInterval(second))
        }
        XCTAssertNil(core.lastError)
        XCTAssertEqual(port.value(FanKeys.mode(0)), 1)
        XCTAssertEqual(port.value(FanKeys.mode(1)), 1)
        XCTAssertEqual(port.value(FanKeys.target(0)) ?? 0, CurveMath.rpm(percent: 25, minimum: 2317, maximum: 7826), accuracy: 1)
    }

    func testCurveGoalIsReachedThroughSlewing() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.curve(balancedCurve)), now: 0)
        inputs.cpu = 80
        for second in 1...60 {
            core.heartbeat(now: TimeInterval(second))
            core.tick(now: TimeInterval(second))
        }
        XCTAssertEqual(port.value(FanKeys.target(0)) ?? 0, 7826, accuracy: 1)
    }

    func testSleepDuringUnlockLeavesNothingBehind() {
        let port = MockPort()
        port.unlockDelayTicks = 6
        let core = makeCore(port: port)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.curve(balancedCurve)), now: 0)
        port.firmwareTick()
        core.willSleep()
        XCTAssertTrue(core.status(protocolVersion: 1).fansUnderControl.isEmpty)
    }

    // Found on real hardware: moving the slider sent fans to maximum, because each change counted as a failed hand-back.
    func testChangingSpeedNeverSendsFansToMaximum() {
        let port = MockPort()
        let core = makeCore(port: port)
        core.clientConnected(now: 0)
        for step in 0...40 {
            _ = core.applyFans(allFans(.constant(percent: step % 2 == 0 ? 15 : 20)), now: Double(step) * 0.2)
        }
        XCTAssertFalse(port.writes.contains { $0.key == FanKeys.target(0) && $0.value > 3500 }, "stays near the requested speed")
        XCTAssertFalse(port.writes.contains { $0.key == FanKeys.mode(0) && $0.value == 0 }, "no hand-back while holding")
        XCTAssertNil(core.lastError)
    }

    func testSpeedChangesSlewFromCurrentSpeed() {
        let port = MockPort()
        let core = makeCore(port: port)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.constant(percent: 0)), now: 0)
        XCTAssertEqual(port.value(FanKeys.target(0)), 2317)
        _ = core.applyFans(allFans(.constant(percent: 50)), now: 1)
        XCTAssertEqual(port.value(FanKeys.target(0)), 2617)
        core.heartbeat(now: 2)
        core.tick(now: 2)
        XCTAssertEqual(port.value(FanKeys.target(0)), 2917)
        for second in 3...20 {
            core.heartbeat(now: TimeInterval(second))
            core.tick(now: TimeInterval(second))
        }
        XCTAssertEqual(port.value(FanKeys.target(0)), 5071.5)
    }

    func testFirstTargetStartsFromActualSpeed() {
        let port = MockPort()
        port.externallySet(FanKeys.actual(0), 3000)
        let core = makeCore(port: port)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.constant(percent: 100)), now: 0)
        XCTAssertEqual(port.value(FanKeys.target(0)), 3300)
    }

    func testMaxAndSupervisorAreImmediate() {
        let port = MockPort()
        let core = makeCore(port: port)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.constant(percent: 0)), now: 0)
        _ = core.applyFans(allFans(.maximum), now: 1)
        XCTAssertEqual(port.value(FanKeys.target(0)), 7826)
    }

    func testFanNotInManualModeNeedsNoWriteToHandBack() {
        let port = MockPort()
        let journal = MemoryStore()
        var left = RestoreJournal()
        left.originalFanModes = [0: 3, 1: 3]
        left.originalUnlock = 0
        _ = journal.save(left)
        makeCore(port: port, journal: journal).start()
        XCTAssertFalse(port.writes.contains { $0.key.description.hasSuffix("Md") }, "the hardware refuses these, so none are sent")
        XCTAssertNil(journal.data)
    }

    func testLeftoversAreClearedEvenWhenControlIsNotAllowed() {
        let port = MockPort()
        port.externallySet(FanKeys.mode(0), 1)
        port.externallySet(KeyWhitelist.unlock, 1)
        let journal = MemoryStore()
        var left = RestoreJournal()
        left.originalFanModes = [0: 3]
        left.originalUnlock = 0
        _ = journal.save(left)
        let core = makeCore(port: port, journal: journal, fanCapability: .unavailable("off"))
        port.rejectKeys = [FanKeys.mode(0)]
        core.start()
        XCTAssertTrue(core.needsTimer)
        port.rejectKeys = []
        core.tick(now: 1)
        XCTAssertEqual(port.value(KeyWhitelist.unlock), 0)
        XCTAssertEqual(port.value(FanKeys.mode(0)), 3)
        XCTAssertNil(journal.data)
    }

    // Found on real hardware: mode writes are refused for seconds after unlocking, which made fans stop.
    func testRefusalsRightAfterUnlockingAreWaitedOut() {
        let port = MockPort()
        port.unlockDelayTicks = 4
        let core = makeCore(port: port)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.constant(percent: 0)), now: 0)
        XCTAssertNil(core.lastError)
        for second in 1...6 {
            port.firmwareTick()
            core.heartbeat(now: TimeInterval(second))
            core.tick(now: TimeInterval(second))
        }
        XCTAssertNil(core.lastError)
        XCTAssertEqual(port.value(KeyWhitelist.unlock), 1)
        for fan in 0...1 {
            XCTAssertEqual(port.value(FanKeys.mode(fan)), 1, "fan \(fan)")
            XCTAssertEqual(port.value(FanKeys.target(fan)), 2317, "fan \(fan)")
        }
    }

    func testManualModeThatNeverArrivesFailsAfterTheWindow() {
        let port = MockPort()
        let core = makeCore(port: port)
        core.clientConnected(now: 0)
        port.rejectKeys = [FanKeys.mode(0), FanKeys.mode(1)]
        _ = core.applyFans(allFans(.maximum), now: 0)
        for second in 1...14 {
            core.heartbeat(now: TimeInterval(second))
            core.tick(now: TimeInterval(second))
        }
        XCTAssertNil(core.lastError, "still inside the window")
        core.heartbeat(now: 16)
        core.tick(now: 16)
        XCTAssertNotNil(core.lastError)
    }

    // Found on real hardware: a slow read-back of `Ftst` left a record behind with nothing to retry it.
    func testUnlockThatFailsToRestoreIsRetried() {
        let port = MockPort()
        let journal = MemoryStore()
        let core = makeCore(port: port, journal: journal)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.maximum), now: 0)
        port.rejectKeys = [KeyWhitelist.unlock]
        core.restoreDefaults()
        XCTAssertTrue(core.needsTimer, "a timer must exist to retry")
        XCTAssertNotNil(journal.data)
        port.rejectKeys = []
        core.tick(now: 1)
        XCTAssertEqual(port.value(KeyWhitelist.unlock), 0)
        XCTAssertNil(journal.data)
        XCTAssertFalse(core.needsTimer)
    }

    func testExitHandsBackButKeepsChargePolicy() {
        let port = MockPort()
        let inputs = MockInputs()
        let journal = MemoryStore()
        let charge = MemoryStore()
        inputs.percent = 90
        let core = makeCore(port: port, inputs: inputs, journal: journal, charge: charge)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.maximum), now: 0)
        _ = core.applyCharge(ChargeRequest(enabled: true, limit: 80, sailing: 5, heatProtection: false, heatLimit: 40, dischargeToLimit: false, topUp: false), now: 0)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 1)
        core.prepareForExit()
        assertSystemControl(port)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 0)
        XCTAssertNil(journal.data)
        XCTAssertNotNil(charge.data)
    }

    func testRestoreDefaultsClearsEverything() {
        let port = MockPort()
        let journal = MemoryStore()
        let core = controlled(port: port, journal: journal)
        core.restoreDefaults()
        assertSystemControl(port)
        XCTAssertNil(journal.data)
        XCTAssertFalse(core.needsTimer)
    }
}

final class SupervisorTests: XCTestCase {
    private func summary(cpu: Double? = 50, gpu: Double? = 40, ssd: Double? = 30, battery: Double? = 25) -> TemperatureSummary {
        TemperatureSummary(cpuHottest: cpu, cpuAverage: cpu, gpu: gpu, ssd: ssd, battery: battery)
    }

    /// Feeds one summary per second from `start`, and returns whether the supervisor was engaged after the last.
    @discardableResult
    private func feed(_ supervisor: inout ThermalSupervisor, _ value: TemperatureSummary, seconds: ClosedRange<Int>) -> Bool {
        var engaged = false
        for second in seconds { engaged = supervisor.update(summary: value, now: TimeInterval(second)) }
        return engaged
    }

    // Invariant 4. Owner report, 2026-11-18: one-second bursts on a P-core sent fans to maximum.
    func testShortSpikesDoNotEngage() {
        var supervisor = ThermalSupervisor()
        feed(&supervisor, summary(cpu: 70), seconds: 0...10)
        XCTAssertFalse(feed(&supervisor, summary(cpu: 104), seconds: 11...13), "a three-second spike is skipped")
        XCTAssertFalse(feed(&supervisor, summary(cpu: 70), seconds: 14...30))
        XCTAssertEqual(supervisor.boostPercent, 0)
    }

    func testSustainedHeatEngagesInStepsAndRecovers() {
        var supervisor = ThermalSupervisor()
        XCTAssertFalse(feed(&supervisor, summary(cpu: 101), seconds: 0...6), "an average needs most of a window")
        XCTAssertTrue(feed(&supervisor, summary(cpu: 101), seconds: 7...8))
        XCTAssertNotNil(supervisor.reason)
        XCTAssertEqual(supervisor.boostPercent, 25)
        feed(&supervisor, summary(cpu: 101), seconds: 9...13)
        XCTAssertEqual(supervisor.boostPercent, 50, "one more step after five seconds")
        XCTAssertEqual(supervisor.boosted(40), 90)
        XCTAssertTrue(feed(&supervisor, summary(cpu: 94), seconds: 14...30), "still inside the recovery band")
        XCTAssertFalse(feed(&supervisor, summary(cpu: 85), seconds: 31...45))
        XCTAssertNil(supervisor.reason)
        XCTAssertEqual(supervisor.boostPercent, 0)
        XCTAssertEqual(supervisor.boosted(40), 40)
    }

    func testCriticalSampleEngagesAtOnceAtFullSpeed() {
        var supervisor = ThermalSupervisor()
        XCTAssertTrue(supervisor.update(summary: summary(cpu: 108), now: 0))
        XCTAssertEqual(supervisor.boostPercent, 100)
        supervisor = ThermalSupervisor()
        XCTAssertTrue(supervisor.update(summary: summary(gpu: 109), now: 0))
        XCTAssertEqual(supervisor.boostPercent, 100)
    }

    func testAnySustainedSensorEngages() {
        var supervisor = ThermalSupervisor()
        XCTAssertTrue(feed(&supervisor, summary(gpu: 100), seconds: 0...10))
        supervisor = ThermalSupervisor()
        XCTAssertTrue(feed(&supervisor, summary(ssd: 75), seconds: 0...10))
        supervisor = ThermalSupervisor()
        XCTAssertTrue(feed(&supervisor, summary(battery: 50), seconds: 0...10))
    }

    /// Owner's request, 2026-11-26: protection goes to the top of the curve, not to the fans' maximum.
    func testCriticalReadingJumpsToTheCurveTop() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        let quiet = FanCurve(points: [.init(temperature: 45, percent: 0), .init(temperature: 100, percent: 80)])
        _ = core.applyFans(FanRequest(policies: [0: .curve(quiet), 1: .curve(quiet)], sensor: .cpuHottest, response: .fast), now: 0)
        inputs.cpu = 109
        core.heartbeat(now: 1)
        core.tick(now: 1)
        XCTAssertEqual(port.value(FanKeys.target(0)) ?? 0, CurveMath.rpm(percent: 80, minimum: 2317, maximum: 7826), accuracy: 1)
        XCTAssertNotNil(core.status(protocolVersion: 1).supervisorReason)
        inputs.cpu = 50
        for second in 2...60 {
            core.heartbeat(now: TimeInterval(second))
            core.tick(now: TimeInterval(second))
        }
        XCTAssertNil(core.status(protocolVersion: 1).supervisorReason)
        XCTAssertLessThan(port.value(FanKeys.target(0)) ?? 0, CurveMath.rpm(percent: 20, minimum: 2317, maximum: 7826), "the curve resumes after recovery")
    }

    func testFixedSpeedIsItsOwnCeiling() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.constant(percent: 70)), now: 0)
        inputs.cpu = 108
        for second in 1...30 {
            core.heartbeat(now: TimeInterval(second))
            core.tick(now: TimeInterval(second))
        }
        XCTAssertEqual(port.value(FanKeys.target(0)) ?? 0, CurveMath.rpm(percent: 70, minimum: 2317, maximum: 7826), accuracy: 1)
    }

    func testFailedOverrideHandsBackToSystem() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        let quiet = FanCurve(points: [.init(temperature: 45, percent: 0), .init(temperature: 100, percent: 80)])
        _ = core.applyFans(FanRequest(policies: [0: .curve(quiet), 1: .curve(quiet)], sensor: .cpuHottest, response: .fast), now: 0)
        port.rejectKeys = [FanKeys.target(0)]
        inputs.cpu = 109
        for second in 1...7 {
            core.heartbeat(now: TimeInterval(second))
            core.tick(now: TimeInterval(second))
        }
        XCTAssertEqual(port.value(FanKeys.mode(0)), 3)
    }

    func testDoesNothingWhenFansAreOnSystemControl() {
        let port = MockPort()
        let inputs = MockInputs()
        inputs.cpu = 99
        let core = makeCore(port: port, inputs: inputs)
        core.tick(now: 1)
        XCTAssertTrue(port.writes.isEmpty, "the firmware is already in charge")
    }
}

final class LimitsAndReadbackTests: XCTestCase {
    // Invariant 5.
    func testTargetsAlwaysStayInsideHardwareLimits() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.curve(balancedCurve)), now: 0)
        for second in 1...120 {
            inputs.cpu = 20 + Double(second)
            core.heartbeat(now: TimeInterval(second))
            core.tick(now: TimeInterval(second))
        }
        let targets = port.writes.filter { $0.key == FanKeys.target(0) }.map(\.value)
        XCTAssertFalse(targets.isEmpty)
        for target in targets { XCTAssertTrue((2317...7826).contains(target), "\(target)") }
    }

    func testRPMMathClamps() {
        XCTAssertEqual(CurveMath.rpm(percent: -50, minimum: 2317, maximum: 7826), 2317)
        XCTAssertEqual(CurveMath.rpm(percent: 500, minimum: 2317, maximum: 7826), 7826)
    }

    // Invariant 6.
    func testReadbackMismatchIsGivenUpOnAfterTheSettleWindow() {
        let port = MockPort()
        let core = makeCore(port: port)
        core.clientConnected(now: 0)
        port.ignoreWrites = true
        _ = core.applyFans(allFans(.maximum), now: 0)
        XCTAssertNil(core.lastError, "a late read-back is normal at first")
        for second in 1...16 {
            core.heartbeat(now: TimeInterval(second))
            core.tick(now: TimeInterval(second))
        }
        XCTAssertNotNil(core.lastError)
        let attempts = port.writes.filter { $0.key == KeyWhitelist.unlock && $0.value == 1 }.count
        XCTAssertLessThanOrEqual(attempts, 16, "retries are bounded")
        port.clearWrites()
        core.heartbeat(now: 30)
        core.tick(now: 30)
        XCTAssertFalse(port.writes.contains { $0.key == KeyWhitelist.unlock && $0.value == 1 }, "stopped trying")
    }

    func testRejectedWriteFaultsAndStopsWriting() {
        let port = MockPort()
        let core = makeCore(port: port)
        core.clientConnected(now: 0)
        port.rejectKeys = [FanKeys.target(1)]
        _ = core.applyFans(allFans(.maximum), now: 0)
        for second in 1...7 {
            core.heartbeat(now: TimeInterval(second))
            core.tick(now: TimeInterval(second))
        }
        XCTAssertNotNil(core.lastError)
        XCTAssertEqual(port.value(FanKeys.mode(0)), 3, "fan 0 is released too")
        XCTAssertEqual(port.value(FanKeys.mode(1)), 3)
        port.clearWrites()
        core.heartbeat(now: 9)
        core.tick(now: 9)
        XCTAssertFalse(port.writes.contains { $0.key == FanKeys.target(0) }, "no write loop")
    }

    // Found on real hardware: "readbackMismatch(F1Tg)" handed back fans that were obeying their targets.
    func testLateTargetReadBackIsNotAFailure() {
        let port = MockPort()
        port.lateTargets = true
        let core = makeCore(port: port)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.constant(percent: 0)), now: 0)
        for second in 1...30 {
            _ = core.applyFans(allFans(.constant(percent: second % 2 == 0 ? 10 : 30)), now: TimeInterval(second))
            port.settleLateValues()
        }
        XCTAssertNil(core.lastError)
        XCTAssertEqual(port.value(FanKeys.mode(0)), 1)
        XCTAssertEqual(port.value(FanKeys.mode(1)), 1)
    }

    func testTargetThatNeverReadsBackIsGivenUpOn() {
        let port = MockPort()
        let core = makeCore(port: port)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.constant(percent: 50)), now: 0)
        port.ignoreWrites = true
        port.externallySet(FanKeys.target(1), 2502)
        for second in 1...4 {
            core.heartbeat(now: TimeInterval(second))
            core.tick(now: TimeInterval(second))
            XCTAssertNil(core.lastError, "tick \(second)")
        }
        port.ignoreWrites = false
        for second in 5...12 {
            port.externallySet(FanKeys.target(1), 2502)
            core.heartbeat(now: TimeInterval(second))
            core.tick(now: TimeInterval(second))
        }
        XCTAssertNotNil(core.lastError)
        XCTAssertEqual(port.value(FanKeys.mode(0)), 3)
    }

    func testFanThatWillNotReturnKeepsBeingRetriedAndIsReported() {
        let port = MockPort()
        let core = makeCore(port: port)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.maximum), now: 0)
        port.rejectKeys = [FanKeys.mode(0)]
        core.restoreDefaults()
        XCTAssertNil(core.lastError, "brief refusals are normal and are not reported")
        XCTAssertTrue(core.needsTimer, "the timer stays alive to retry")
        for tick in 1...7 { core.tick(now: 0.1 * Double(tick)) }
        XCTAssertNotNil(core.lastError, "a lasting refusal is reported")
        port.rejectKeys = []
        core.tick(now: 1)
        XCTAssertEqual(port.value(FanKeys.mode(0)), 3)
        XCTAssertFalse(core.needsTimer)
    }

    // Invariant 7.
    func testIdenticalTargetsAreNotRewritten() {
        let port = MockPort()
        let core = makeCore(port: port)
        core.clientConnected(now: 0)
        _ = core.applyFans(allFans(.constant(percent: 40)), now: 0)
        port.clearWrites()
        for second in 1...10 {
            core.heartbeat(now: TimeInterval(second))
            core.tick(now: TimeInterval(second))
        }
        XCTAssertTrue(port.writes.isEmpty)
    }

    func testTimerOnlyRunsWhenControlling() {
        let core = makeCore()
        XCTAssertFalse(core.needsTimer, "idle helper: no timer at all")
        _ = core.applyFans(allFans(.maximum), now: 0)
        XCTAssertTrue(core.needsTimer)
        core.restoreDefaults()
        XCTAssertFalse(core.needsTimer)
    }
}

final class CapabilityTests: XCTestCase {
    // Invariant 10.
    func testUnverifiedHardwareStaysReadOnly() {
        let port = MockPort()
        XCTAssertFalse(CapabilityProbe.fans(port: port, fanCount: 2, model: "Mac99,1", osMajor: 27, allowUnverified: false).isAvailable)
        XCTAssertTrue(CapabilityProbe.fans(port: port, fanCount: 2, model: "Mac99,1", osMajor: 27, allowUnverified: true).isAvailable)
        XCTAssertTrue(CapabilityProbe.charge(port: port, hasBattery: true, model: "Mac16,8", osMajor: 27, allowUnverified: false).isAvailable)
        XCTAssertFalse(CapabilityProbe.charge(port: port, hasBattery: true, model: "Mac99,1", osMajor: 27, allowUnverified: false).isAvailable)
    }

    func testOnlyWhatWasTestedIsOnTheVerifiedList() {
        let port = MockPort()
        XCTAssertTrue(CapabilityProbe.fans(port: port, fanCount: 2, model: "Mac16,8", osMajor: 27, allowUnverified: false).isAvailable)
        XCTAssertFalse(CapabilityProbe.fans(port: port, fanCount: 2, model: "Mac16,8", osMajor: 28, allowUnverified: false).isAvailable, "a new macOS needs testing")
        XCTAssertEqual(CapabilityProbe.verified.chargeControl.map(\.model), ["Mac16,8"], "only the Mac where CHIE was tested")
        XCTAssertFalse(CapabilityProbe.charge(port: port, hasBattery: true, model: "Mac16,8", osMajor: 28, allowUnverified: false).isAvailable)
    }

    func testVerifiedListEnablesOnlyThatCombination() {
        var verified = CapabilityProbe.Verified()
        verified.fanControl = [("Mac16,8", 27)]
        let port = MockPort()
        XCTAssertTrue(CapabilityProbe.fans(port: port, fanCount: 2, model: "Mac16,8", osMajor: 27, allowUnverified: false, verified: verified).isAvailable)
        XCTAssertFalse(CapabilityProbe.fans(port: port, fanCount: 2, model: "Mac16,8", osMajor: 28, allowUnverified: false, verified: verified).isAvailable, "a macOS update disables it")
    }

    func testProbeMismatchDisablesEvenWhenAllowed() {
        XCTAssertFalse(CapabilityProbe.fans(port: MockPort(fans: 1), fanCount: 2, model: "x", osMajor: 27, allowUnverified: true).isAvailable, "missing keys")
        XCTAssertFalse(CapabilityProbe.fans(port: MockPort(), fanCount: 0, model: "x", osMajor: 27, allowUnverified: true).isAvailable, "no fans")
        XCTAssertFalse(CapabilityProbe.charge(port: MockPort(withCharge: false), hasBattery: true, model: "x", osMajor: 27, allowUnverified: true).isAvailable)
        XCTAssertFalse(CapabilityProbe.charge(port: MockPort(), hasBattery: false, model: "x", osMajor: 27, allowUnverified: true).isAvailable)
    }
}

/// Pause Charging: `CHIE` = 1 sets the adapter aside, so the battery runs down until the pause ends.
final class ChargePauseTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    }

    private func pause(hours: Double?, untilPercent: Int?, from clock: Clock) -> ChargeRequest {
        var request = ChargeRequest.off
        request.pause = ChargePause(until: hours.map { clock.now.addingTimeInterval($0 * 3600) }, untilPercent: untilPercent)
        return request
    }

    private func makePausingCore(_ port: MockPort, _ inputs: MockInputs, _ clock: Clock, store: MemoryStore = MemoryStore()) -> ControlCore {
        ControlCore(
            inputs: inputs, port: port, journalStore: MemoryStore(), chargeStore: store,
            fanCapability: .available, chargeCapability: .available, wallClock: { clock.now }
        )
    }

    func testPauseEndsAtTheChosenLevel() {
        let port = MockPort(), inputs = MockInputs(), clock = Clock()
        inputs.percent = 80
        inputs.isCharging = false
        let core = makePausingCore(port, inputs, clock)
        _ = core.applyCharge(pause(hours: nil, untilPercent: 50, from: clock), now: 0)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 1, "adapter set aside")
        XCTAssertTrue(core.needsTimer)
        inputs.percent = 51
        core.tick(now: 1)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 1)
        inputs.percent = 50
        core.tick(now: 2)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 0)
        XCTAssertNil(core.status(protocolVersion: 2).chargeRequest.pause, "a finished pause is cleared")
        XCTAssertFalse(core.needsTimer, "nothing left to watch")
    }

    func testPauseEndsAtTheChosenTime() {
        let port = MockPort(), inputs = MockInputs(), clock = Clock()
        inputs.percent = 90
        inputs.isCharging = false
        let core = makePausingCore(port, inputs, clock)
        _ = core.applyCharge(pause(hours: 1, untilPercent: nil, from: clock), now: 0)
        clock.now += 3599
        core.tick(now: 3599)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 1)
        clock.now += 1
        core.tick(now: 3600)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 0)
    }

    // Invariant 8: the floor ends a pause whatever it asked for.
    func testPauseNeverRunsBelowTheFloor() {
        let port = MockPort(), inputs = MockInputs(), clock = Clock()
        inputs.percent = 40
        inputs.isCharging = false
        let core = makePausingCore(port, inputs, clock)
        _ = core.applyCharge(pause(hours: 5, untilPercent: 5, from: clock), now: 0)
        XCTAssertEqual(core.status(protocolVersion: 2).chargeRequest.pause?.untilPercent, 20, "clamped to the floor")
        inputs.percent = 20
        core.tick(now: 1)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 0)
    }

    func testUnreadableBatteryEndsThePauseAtOnce() {
        let port = MockPort(), inputs = MockInputs(), clock = Clock()
        inputs.percent = 80
        inputs.isCharging = false
        let core = makePausingCore(port, inputs, clock)
        _ = core.applyCharge(pause(hours: 1, untilPercent: nil, from: clock), now: 0)
        inputs.percent = nil
        core.tick(now: 1)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 0)
    }

    func testSleepAllowsChargingAndWakeResumesThePause() {
        let port = MockPort(), inputs = MockInputs(), clock = Clock()
        inputs.percent = 80
        inputs.isCharging = false
        let core = makePausingCore(port, inputs, clock)
        _ = core.applyCharge(pause(hours: 2, untilPercent: nil, from: clock), now: 0)
        core.willSleep()
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 0, "the battery must not drain unattended")
        clock.now += 600
        core.didWake(now: 600)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 1)
    }

    func testPauseIsCappedAtADay() {
        let clock = Clock()
        let levelOnly = ChargeStateMachine.validated(pause(hours: nil, untilPercent: 50, from: clock), now: clock.now)
        XCTAssertEqual(levelOnly.pause?.until, clock.now.addingTimeInterval(ChargeStateMachine.longestPause))
        let long = ChargeStateMachine.validated(pause(hours: 100, untilPercent: nil, from: clock), now: clock.now)
        XCTAssertEqual(long.pause?.until, clock.now.addingTimeInterval(ChargeStateMachine.longestPause))
        XCTAssertNil(ChargeStateMachine.clamped(pause(hours: nil, untilPercent: nil, from: clock)).pause, "no end means no pause")
    }

    func testPauseSurvivesAHelperRestart() {
        let port = MockPort(), inputs = MockInputs(), clock = Clock(), store = MemoryStore()
        inputs.percent = 80
        inputs.isCharging = false
        _ = makePausingCore(port, inputs, clock, store: store).applyCharge(pause(hours: 1, untilPercent: 50, from: clock), now: 0)
        let next = makePausingCore(port, inputs, clock, store: store)
        next.start()
        next.tick(now: 1)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 1)
    }

    func testRestoreDefaultsEndsThePause() {
        let port = MockPort(), inputs = MockInputs(), clock = Clock()
        inputs.percent = 80
        inputs.isCharging = false
        let core = makePausingCore(port, inputs, clock)
        _ = core.applyCharge(pause(hours: 1, untilPercent: nil, from: clock), now: 0)
        core.restoreDefaults()
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 0)
        XCTAssertNil(core.status(protocolVersion: 2).chargeRequest.pause)
    }
}

final class ChargeControlTests: XCTestCase {
    private func request(limit: Int = 80) -> ChargeRequest {
        ChargeRequest(enabled: true, limit: limit, sailing: 5, heatProtection: true, heatLimit: 40, dischargeToLimit: false, topUp: false)
    }

    func testHoldsAtLimitAndRestoresOnDisable() {
        let port = MockPort()
        let inputs = MockInputs()
        inputs.percent = 80
        let core = makeCore(port: port, inputs: inputs)
        _ = core.applyCharge(request(), now: 0)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 1)
        core.restoreDefaults()
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 0)
    }

    func testKeepsWorkingWithoutTheApp() {
        let port = MockPort()
        let inputs = MockInputs()
        inputs.percent = 79
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        _ = core.applyCharge(request(), now: 0)
        core.clientDisconnected(now: 1)
        inputs.percent = 80
        core.tick(now: 100)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 1)
    }

    func testPolicySurvivesRestart() {
        let port = MockPort()
        let inputs = MockInputs()
        let store = MemoryStore()
        let core = makeCore(port: port, inputs: inputs, charge: store)
        _ = core.applyCharge(request(), now: 0)
        let next = makeCore(port: port, inputs: inputs, charge: store)
        XCTAssertEqual(next.status(protocolVersion: 1).chargeRequest.limit, 80)
    }

    // Invariant 8.
    func testUnreadableBatteryEnablesCharging() {
        let port = MockPort()
        let inputs = MockInputs()
        inputs.percent = 90
        let core = makeCore(port: port, inputs: inputs)
        _ = core.applyCharge(request(), now: 0)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 1)
        inputs.percent = nil
        core.tick(now: 1)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 0)
    }

    func testInhibitThatHasNoEffectIsTurnedOff() {
        let port = MockPort()
        let inputs = MockInputs()
        inputs.percent = 90
        inputs.isCharging = true
        let core = makeCore(port: port, inputs: inputs)
        _ = core.applyCharge(request(), now: 0)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 1)
        core.tick(now: 30)
        XCTAssertNil(core.lastError, "telemetry can lag")
        core.tick(now: 61)
        XCTAssertNotNil(core.lastError)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 0)
    }

    // Found on real hardware: CHIE does not echo a written 1, and each request wrote it again in a loop.
    func testKeyThatDoesNotEchoIsWrittenOnce() {
        let port = MockPort()
        let inputs = MockInputs()
        inputs.percent = 90
        inputs.isCharging = false
        port.ignoreWrites = true
        let core = makeCore(port: port, inputs: inputs)
        for second in 0...30 {
            _ = core.applyCharge(request(), now: TimeInterval(second))
            core.tick(now: TimeInterval(second) + 0.5)
        }
        XCTAssertNil(core.lastError, "charging stopped, so the write worked")
        XCTAssertEqual(port.writes.filter { $0.key == KeyWhitelist.chargeInhibit }.count, 1)
    }

    func testRepeatOfAFailedChargeRequestDoesNotRetry() {
        let port = MockPort()
        let inputs = MockInputs()
        inputs.percent = 90
        port.rejectAll = true
        let core = makeCore(port: port, inputs: inputs)
        _ = core.applyCharge(request(), now: 0)
        XCTAssertNotNil(core.lastError)
        let tried = port.writes.count
        for second in 1...10 { _ = core.applyCharge(request(), now: TimeInterval(second)) }
        XCTAssertEqual(port.writes.count, tried)
    }

    func testCannotSaveRecordMeansNoChargeWrite() {
        let port = MockPort()
        let inputs = MockInputs()
        let journal = MemoryStore()
        inputs.percent = 90
        journal.failSaves = true
        let core = makeCore(port: port, inputs: inputs, journal: journal)
        _ = core.applyCharge(request(), now: 0)
        XCTAssertTrue(port.writes.isEmpty)
        XCTAssertNotNil(core.lastError)
    }

    func testStuckInhibitKeepsRetryingTowardSafeState() {
        let port = MockPort()
        let inputs = MockInputs()
        inputs.percent = 90
        let core = makeCore(port: port, inputs: inputs)
        _ = core.applyCharge(request(), now: 0)
        port.rejectAll = true
        inputs.percent = nil
        core.tick(now: 1)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 1)
        port.rejectAll = false
        core.tick(now: 2)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 0)
    }

    func testCrashWhileInhibitedIsUndoneAtStart() {
        let port = MockPort()
        let inputs = MockInputs()
        let journal = MemoryStore()
        inputs.percent = 90
        let core = makeCore(port: port, inputs: inputs, journal: journal)
        _ = core.applyCharge(request(), now: 0)
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 1)
        makeCore(port: port, inputs: inputs, journal: journal).start()
        XCTAssertEqual(port.value(KeyWhitelist.chargeInhibit), 0)
    }
}

/// Owner report, 2026-11-18: with a curve topping out at 66%, a short burst of work in a photo app sent fans to maximum.
final class SpikeAndFloorTests: XCTestCase {
    private let lowCurve = FanCurve(points: [.init(temperature: 45, percent: 0), .init(temperature: 100, percent: 50)])

    private func run(_ core: ControlCore, _ inputs: MockInputs, cpu: Double, seconds: ClosedRange<Int>) {
        inputs.cpu = cpu
        for second in seconds {
            core.heartbeat(now: TimeInterval(second))
            core.tick(now: TimeInterval(second))
        }
    }

    private func targets(_ port: MockPort) -> [Double] {
        port.writes.filter { $0.key == FanKeys.target(0) }.map(\.value)
    }

    func testShortSpikeOnTheControlSensorIsSkipped() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        _ = core.applyFans(FanRequest(policies: [0: .curve(lowCurve), 1: .curve(lowCurve)], sensor: .cpuHottest, response: .normal), now: 0)
        run(core, inputs, cpu: 60, seconds: 1...20)
        let settled = port.value(FanKeys.target(0)) ?? 0
        run(core, inputs, cpu: 104, seconds: 21...25)
        XCTAssertEqual(port.value(FanKeys.target(0)) ?? 0, settled, accuracy: 30, "a five-second burst changes nothing")
        run(core, inputs, cpu: 60, seconds: 26...40)
        XCTAssertEqual(port.value(FanKeys.target(0)) ?? 0, settled, accuracy: 30)
    }

    func testCurveTopIsTheCeilingBelowTheSupervisor() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        _ = core.applyFans(FanRequest(policies: [0: .curve(lowCurve), 1: .curve(lowCurve)], sensor: .cpuHottest, response: .fast), now: 0)
        // 99 °C held: under the supervisor's 100 °C average. The floor at 99 °C is 36%, under the curve's 49%.
        run(core, inputs, cpu: 99, seconds: 1...90)
        let ceiling = CurveMath.rpm(percent: 50, minimum: 2317, maximum: 7826)
        XCTAssertNil(core.status(protocolVersion: 1).supervisorReason)
        for target in targets(port) { XCTAssertLessThanOrEqual(target, ceiling + 1) }
        XCTAssertEqual(port.value(FanKeys.target(0)) ?? 0, CurveMath.rpm(percent: CurveMath.percent(at: 99, curve: lowCurve), minimum: 2317, maximum: 7826), accuracy: 1)
    }

    func testNoRequestIsWeakerThanTheMacOSFloor() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        // A curve following the SSD stays cool while the CPU is hot: the floor follows the CPU anyway.
        let flat = FanCurve(points: [.init(temperature: 30, percent: 0), .init(temperature: 100, percent: 0)])
        _ = core.applyFans(FanRequest(policies: [0: .curve(flat), 1: .constant(percent: 0)], sensor: .ssd, response: .fast), now: 0)
        run(core, inputs, cpu: 98, seconds: 1...60)
        let floor = CurveMath.rpm(percent: CurveMath.floorPercent(at: 98), minimum: 2317, maximum: 7826)
        XCTAssertEqual(port.value(FanKeys.target(0)) ?? 0, floor, accuracy: 1)
        XCTAssertEqual(port.value(FanKeys.target(1)) ?? 0, floor, accuracy: 1)
    }

    /// The control sensor stays cool while the CPU is hot, so only protection lifts the fans, in steps, up to the
    /// curve's top point and never to the fans' maximum.
    func testSustainedHeatStepsUpToTheCurveTop() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        let top = FanCurve(points: [.init(temperature: 40, percent: 0), .init(temperature: 80, percent: 90)])
        _ = core.applyFans(FanRequest(policies: [0: .curve(top), 1: .curve(top)], sensor: .ssd, response: .fast), now: 0)
        run(core, inputs, cpu: 90, seconds: 1...40)
        let before = port.value(FanKeys.target(0)) ?? 0
        run(core, inputs, cpu: 102, seconds: 41...50)
        XCTAssertNotNil(core.status(protocolVersion: 1).supervisorReason)
        let boosted = port.value(FanKeys.target(0)) ?? 0
        XCTAssertGreaterThan(boosted, before + 1000, "a step adds a quarter of the range at once")
        XCTAssertLessThan(boosted, CurveMath.rpm(percent: 90, minimum: 2317, maximum: 7826) - 1, "steps, not straight to the top")
        run(core, inputs, cpu: 102, seconds: 51...70)
        XCTAssertEqual(port.value(FanKeys.target(0)) ?? 0, CurveMath.rpm(percent: 90, minimum: 2317, maximum: 7826), accuracy: 1, "the curve's top is the ceiling")
    }
}

/// Owner's request, 2026-11-26: the limits can be moved and protection turned off, with a last resort that stays.
final class ConfigurableProtectionTests: XCTestCase {
    private let lowCurve = FanCurve(points: [.init(temperature: 45, percent: 0), .init(temperature: 100, percent: 50)])

    private func request(_ protection: OverheatProtection) -> FanRequest {
        FanRequest(policies: [0: .curve(lowCurve), 1: .curve(lowCurve)], sensor: .cpuHottest, response: .fast, protection: protection)
    }

    private func run(_ core: ControlCore, _ inputs: MockInputs, cpu: Double, seconds: ClosedRange<Int>) {
        inputs.cpu = cpu
        for second in seconds {
            core.heartbeat(now: TimeInterval(second))
            core.tick(now: TimeInterval(second))
        }
    }

    func testValuesAreClampedAndNeverCross() {
        let wild = OverheatProtection(enabled: true, sustainedCelsius: 200, criticalCelsius: 50).clamped
        XCTAssertEqual(wild.sustainedCelsius, 105)
        XCTAssertEqual(wild.criticalCelsius, 108, "at least 3 °C above the sustained limit")
        let low = OverheatProtection(enabled: true, sustainedCelsius: 20, criticalCelsius: .nan).clamped
        XCTAssertEqual(low.sustainedCelsius, 85)
        XCTAssertEqual(low.criticalCelsius, 108)
    }

    func testALowerLimitEngagesEarlier() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        _ = core.applyFans(request(OverheatProtection(enabled: true, sustainedCelsius: 90, criticalCelsius: 100)), now: 0)
        run(core, inputs, cpu: 92, seconds: 1...20)
        XCTAssertNotNil(core.status(protocolVersion: 4).supervisorReason)
    }

    func testOffMeansTheCurveHoldsWhenHot() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        var off = OverheatProtection.standard
        off.enabled = false
        _ = core.applyFans(request(off), now: 0)
        run(core, inputs, cpu: 109, seconds: 1...60)
        XCTAssertNil(core.status(protocolVersion: 4).supervisorReason, "neither the average nor a critical reading engages")
        // The macOS minimum still applies with protection off: 67% at 109 °C, above this curve's 50%.
        let ceiling = CurveMath.rpm(percent: max(50, CurveMath.floorPercent(at: 109)), minimum: 2317, maximum: 7826)
        let targets = port.writes.filter({ $0.key == FanKeys.target(0) }).map(\.value)
        for target in targets { XCTAssertLessThanOrEqual(target, ceiling + 1) }
        XCTAssertLessThan(targets.max() ?? 0, 7826, "no step up to maximum")
        XCTAssertEqual(port.value(FanKeys.mode(0)), 1, "still under the owner's control at 109 °C")
    }

    func testOffStillHandsBackToMacOSAt110() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        var off = OverheatProtection.standard
        off.enabled = false
        _ = core.applyFans(request(off), now: 0)
        run(core, inputs, cpu: 90, seconds: 1...20)
        run(core, inputs, cpu: 112, seconds: 21...40)
        XCTAssertEqual(port.value(FanKeys.mode(0)), 3, "back under macOS control")
        XCTAssertEqual(port.value(FanKeys.mode(1)), 3)
        XCTAssertEqual(port.value(KeyWhitelist.unlock), 0)
        XCTAssertNil(core.status(protocolVersion: 4).fanRequest)
        XCTAssertNotNil(core.lastError)
    }

    func testOnAlsoHandsBackToMacOSAt110() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        _ = core.applyFans(request(.standard), now: 0)
        run(core, inputs, cpu: 90, seconds: 1...20)
        run(core, inputs, cpu: 112, seconds: 21...40)
        XCTAssertEqual(port.value(FanKeys.mode(0)), 3, "the curve's top was not enough, so macOS takes over")
        XCTAssertNil(core.status(protocolVersion: 4).fanRequest)
    }

    func testTurningItBackOnRestoresTheSupervisor() {
        let port = MockPort()
        let inputs = MockInputs()
        let core = makeCore(port: port, inputs: inputs)
        core.clientConnected(now: 0)
        var off = OverheatProtection.standard
        off.enabled = false
        _ = core.applyFans(request(off), now: 0)
        run(core, inputs, cpu: 104, seconds: 1...20)
        XCTAssertNil(core.status(protocolVersion: 4).supervisorReason)
        _ = core.applyFans(request(.standard), now: 21)
        run(core, inputs, cpu: 104, seconds: 22...35)
        XCTAssertNotNil(core.status(protocolVersion: 4).supervisorReason)
    }
}
