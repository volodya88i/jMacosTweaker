import Core
import Foundation
import Shared

public struct FanLimits: Equatable, Sendable {
    public var minimum: Double
    public var maximum: Double

    public init(minimum: Double, maximum: Double) {
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// What the loop needs to read. Mocked in tests.
public protocol ControlInputs: Sendable {
    var fanLimits: [Int: FanLimits] { get }
    /// Temperature readings. Empty means the source failed. `full` includes sensors outside the summary groups.
    func readings(full: Bool) -> [SensorReading]
    func summary(_ readings: [SensorReading]) -> TemperatureSummary
    func battery() -> ChargeInputs
}

/// All control decisions, driven by explicit events and a passed-in clock, so every failure path is testable.
/// Not thread-safe: the daemon calls it from one serial queue.
public final class ControlCore: @unchecked Sendable {
    public struct Timing: Sendable {
        /// After the app disconnects, fans return to system control this soon. Invariant 3.
        public var disconnectGrace: TimeInterval = 5
        public var heartbeatTimeout: TimeInterval = 20
        public var sensorStaleAfter: TimeInterval = 5
        /// Consecutive ticks a fan may differ from what was written before control is given up.
        public var maxReasserts = 5
        public var slewPerSecond = 300.0
        public var inhibitEffectTimeout: TimeInterval = 60
        /// How long the hardware may refuse manual mode after unlocking. On Mac16,8, `Ftst` reads back late and mode
        /// writes are refused for about 3 to 5 s, until the fans have spun up. Firmware controls the fans meanwhile.
        public var unlockSettle: TimeInterval = 15
        /// Ticks of failed hand-back before fans are sent to maximum, which is loud but cannot overheat anything.
        public var releaseFailuresBeforeMaximum = 10
        public init() {}
    }

    private let inputs: any ControlInputs
    private let writer: VerifiedWriter
    private let port: any SMCPort
    private let journalStore: any KeyValueStore
    private let chargeStore: any KeyValueStore
    private let timing: Timing
    /// Wall clock for charge pauses, which end at a time of day. Injected for tests.
    private let wallClock: @Sendable () -> Date

    public private(set) var fanCapability: Capability
    public private(set) var chargeCapability: Capability

    private var fanRequest: FanRequest?
    private var chargeRequest: ChargeRequest
    private var chargeMachine = ChargeStateMachine()
    private var appliedCharge: ChargeAction = .allowCharging
    private var chargeChangedAt: TimeInterval = 0
    private var ramps: [Int: FanRamp] = [:]
    private var manualFans: Set<Int> = []
    private var targets: [Int: Double] = [:]
    private var supervisor = ThermalSupervisor()
    private var journal = RestoreJournal()
    private var lastHeartbeat: TimeInterval?
    private var disconnectedAt: TimeInterval?
    private var lastGoodSensor: TimeInterval?
    private var lastGoodValue: Double?
    /// Last time the supervisor had a CPU or GPU temperature to judge.
    private var lastSupervisedAt: TimeInterval?
    private var fanFaulted = false
    private var chargeFaulted = false
    private var asleep = false
    private var driftCounts: [Int: Int] = [:]
    private var releaseFailures = 0
    private var unlockRequestedAt: TimeInterval?
    private var lastUnlockAttempt: TimeInterval?
    private var lastSlew: [Int: TimeInterval] = [:]
    private var curveGoals: [Int: Double] = [:]
    /// The control temperature with short spikes removed, for curves.
    private var controlFilter = SpikeFilter(window: FanResponse.normal.spikeWindow)
    /// The hottest CPU or GPU temperature with short spikes removed, for the macOS floor.
    private var floorFilter = SpikeFilter(window: FanResponse.normal.spikeWindow)
    private var clockNow: TimeInterval = 0
    public private(set) var lastError: String?

    public init(
        inputs: any ControlInputs, port: any SMCPort, journalStore: any KeyValueStore, chargeStore: any KeyValueStore,
        fanCapability: Capability, chargeCapability: Capability, timing: Timing = Timing(),
        wallClock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inputs = inputs
        self.port = port
        writer = VerifiedWriter(port: port)
        self.journalStore = journalStore
        self.chargeStore = chargeStore
        self.fanCapability = fanCapability
        self.chargeCapability = chargeCapability
        self.timing = timing
        self.wallClock = wallClock
        chargeRequest = chargeCapability.isAvailable ? (chargeStore.load(ChargeRequest.self) ?? .off) : .off
    }

    /// At start, undo anything a previous run left behind, before accepting any request. Invariants 3 and 7.
    public func start() {
        if let saved = journalStore.load(RestoreJournal.self), !saved.isEmpty {
            journal = saved
            restoreFromJournal()
        }
    }

    public var needsTimer: Bool {
        !asleep && (fanRequestIsActive || chargeRequest.enabled || chargeRequest.pause != nil || !manualFans.isEmpty || appliedCharge != .allowCharging || !journal.isEmpty)
    }

    private var fanRequestIsActive: Bool {
        guard let fanRequest else { return false }
        return fanRequest.policies.values.contains { $0 != .system }
    }

    // MARK: Events

    public func clientConnected(now: TimeInterval) {
        disconnectedAt = nil
        lastHeartbeat = now
    }

    public func clientDisconnected(now: TimeInterval) {
        disconnectedAt = now
    }

    public func heartbeat(now: TimeInterval) {
        lastHeartbeat = now
    }

    public func applyFans(_ request: FanRequest, now: TimeInterval) -> Result<Void, RequestError> {
        guard fanCapability.isAvailable else { return .failure(.unavailable) }
        let validated: FanRequest
        switch Self.validate(request, limits: inputs.fanLimits) {
        case let .success(value): validated = value
        case let .failure(error): return .failure(error)
        }
        fanRequest = validated
        fanFaulted = false
        lastError = nil
        lastHeartbeat = now
        lastGoodSensor = now
        lastSupervisedAt = now
        clockNow = now
        for fan in manualFans where validated.policies[fan] == nil || validated.policies[fan] == .system {
            returnToSystem(fan: fan)
        }
        if !fanRequestIsActive { releaseAllFans() }
        resetCurveState()
        tick(now: now)
        return .success(())
    }

    public func applyCharge(_ request: ChargeRequest, now: TimeInterval) -> Result<Void, RequestError> {
        guard chargeCapability.isAvailable else { return .failure(.unavailable) }
        let clamped = ChargeStateMachine.validated(request, now: wallClock())
        // A repeat of a request that already failed must not retry: that was a write loop on real hardware.
        if chargeFaulted, clamped == chargeRequest { return .failure(.unavailable) }
        chargeRequest = clamped
        chargeFaulted = false
        clockNow = now
        guard chargeStore.save(chargeRequest) else { return .failure(.storageFailed) }
        tick(now: now)
        return .success(())
    }

    /// Everything back to system control. Also the panic button and the uninstall path.
    public func restoreDefaults() {
        fanRequest = nil
        chargeRequest = .off
        chargeStore.remove()
        fanFaulted = false
        chargeFaulted = false
        lastError = nil
        resetCurveState()
        restoreFromJournal()
    }

    /// On SIGTERM: hands everything back but keeps the charge policy, so it applies again at next start.
    public func prepareForExit() {
        fanRequest = nil
        resetCurveState()
        restoreFromJournal()
    }

    public func willSleep() {
        asleep = true
        // Fans have no live controller during sleep, and the battery must not drain unattended: `CHIE` sets the adapter
        // aside, so charging is allowed again. A pause still running picks up again at the first tick after wake.
        releaseAllFans()
        resetCurveState()
        if appliedCharge == .dischargeOnAdapter { applyChargeAction(.allowCharging) }
    }

    public func didWake(now: TimeInterval) {
        asleep = false
        lastGoodSensor = now
        lastSupervisedAt = now
        lastHeartbeat = now
        tick(now: now)
    }

    /// Reported to the app, for example when another tool blocks a request before it reaches this class.
    public func report(error: String) {
        lastError = error
    }

    public func status(protocolVersion: Int) -> HelperStatus {
        HelperStatus(
            protocolVersion: protocolVersion,
            fanCapability: fanCapability,
            chargeCapability: chargeCapability,
            fanRequest: fanRequest,
            chargeRequest: chargeRequest,
            chargeAction: appliedCharge,
            fansUnderControl: manualFans.sorted(),
            targets: targets,
            supervisorReason: supervisor.reason,
            lastError: lastError
        )
    }

    private func resetCurveState() {
        ramps = [:]
        curveGoals = [:]
        let window = (fanRequest?.response ?? .normal).spikeWindow
        controlFilter = SpikeFilter(window: window)
        floorFilter = SpikeFilter(window: window)
    }

    private static func rampTuning(_ response: FanResponse) -> FanRamp.Tuning {
        var tuning = FanRamp.Tuning()
        tuning.rampUpPerSecond = response.rampUpPerSecond
        return tuning
    }

    // MARK: Loop

    /// One evaluation. At most about 1 Hz, and only while `needsTimer` is true.
    public func tick(now: TimeInterval) {
        guard !asleep else { return }
        clockNow = now
        var wantsAllSensors = false
        if case .custom = fanRequest?.sensor { wantsAllSensors = true }
        let readings = inputs.readings(full: wantsAllSensors)
        let summary = inputs.summary(readings)
        tickFans(readings: readings, summary: summary, now: now)
        tickCharge()
    }

    private func tickFans(readings: [SensorReading], summary: TemperatureSummary, now: TimeInterval) {
        guard fanCapability.isAvailable else {
            // Anything left from a run when control was allowed is still handed back.
            if !journal.isEmpty { releaseAllFans() }
            return
        }
        supervisor.update(summary: summary, now: now)
        if summary.cpuHottest != nil || summary.gpu != nil { lastSupervisedAt = now }

        if let reason = staleControllerReason(now: now) {
            releaseAllFans()
            fanRequest = nil
            lastError = reason
            return
        }
        guard let request = fanRequest, fanRequestIsActive, !fanFaulted else {
            releaseAllFans()
            return
        }

        verifyHeldFans()
        guard !fanFaulted else { return }

        // The supervisor cannot protect anything it cannot see. Only Max is safe without temperatures, because nothing
        // cools more. Invariants 3 and 4.
        let onlyMaximum = request.policies.values.allSatisfy { $0 == .maximum || $0 == .system }
        if !onlyMaximum, now - (lastSupervisedAt ?? now) > timing.sensorStaleAfter {
            releaseAllFans()
            fanRequest = nil
            lastError = "CPU and GPU temperatures could not be read, so fans went back to system control."
            return
        }

        // The macOS floor follows the hottest CPU or GPU, whatever the curve follows, so no request is weaker than macOS.
        let hottest = [summary.cpuHottest, summary.gpu].compactMap { $0 }.max()
        let floor = hottest.map { CurveMath.floorPercent(at: floorFilter.add($0, now: now)) } ?? 0
        // While the supervisor is engaged, each fan gets its boost on top, written at once. Invariant 4.
        let boosting = supervisor.isOverriding

        let needsSensor = request.policies.values.contains { if case .curve = $0 { return true } else { return false } }
        var control: Double?
        if needsSensor {
            control = Self.controlValue(request.sensor, readings: readings, summary: summary)
            if let raw = control {
                lastGoodSensor = now
                lastGoodValue = raw
                control = controlFilter.add(raw, now: now)
            } else if now - (lastGoodSensor ?? now) > timing.sensorStaleAfter {
                releaseAllFans()
                fanRequest = nil
                lastError = "The control sensor stopped reporting, so fans went back to system control."
                return
            } else {
                control = lastGoodValue
            }
        }

        for fan in inputs.fanLimits.keys.sorted() {
            guard let policy = request.policies[fan], policy != .system, let limits = inputs.fanLimits[fan] else { continue }
            // A curve with no temperature yet has nothing to command, and manual mode without a target would leave the
            // fan wherever unlocking put it. While boosting, the boost alone is a target.
            if case .curve = policy, control == nil, !boosting { continue }
            // Every tick until accepted, whatever the policy. A curve only produces output when its target changes,
            // which is too rare to get through the seconds of refusals after unlocking.
            if !manualFans.contains(fan), !enterManual(fan: fan) {
                if fanFaulted { return }
                continue
            }
            switch policy {
            case .system:
                break
            case .maximum:
                command(fan: fan, rpm: limits.maximum, immediate: true)
            case let .constant(percent):
                let wanted = supervisor.boosted(max(percent, floor))
                command(fan: fan, rpm: CurveMath.rpm(percent: wanted, minimum: limits.minimum, maximum: limits.maximum), immediate: boosting)
            case let .curve(curve):
                if let control {
                    var ramp = ramps[fan] ?? FanRamp(tuning: Self.rampTuning(request.response ?? .normal))
                    let next = ramp.step(temperature: control, now: now) { temperature in
                        let percent = max(CurveMath.percent(at: temperature, curve: curve), floor)
                        return CurveMath.rpm(percent: percent, minimum: limits.minimum, maximum: limits.maximum)
                    }
                    ramps[fan] = ramp
                    if let next { curveGoals[fan] = next }
                }
                // Sent every tick, because slewing takes several ticks to reach a goal the ramp reports only once.
                let goal = curveGoals[fan] ?? limits.minimum
                if boosting {
                    let percent = supervisor.boosted(CurveMath.percent(rpm: goal, minimum: limits.minimum, maximum: limits.maximum))
                    command(fan: fan, rpm: CurveMath.rpm(percent: percent, minimum: limits.minimum, maximum: limits.maximum), immediate: true)
                } else if curveGoals[fan] != nil {
                    command(fan: fan, rpm: goal)
                }
            }
            if fanFaulted { return }
        }
    }

    /// Firmware or another tool can take a fan back after a write has been confirmed. Observed on Mac16,8: `F1Md` fell
    /// to 0 just after unlocking. So what we hold is re-read every tick, re-asserted a few times, then given up on.
    private func verifyHeldFans() {
        for fan in manualFans.sorted() {
            let modeHeld = port.read(FanKeys.mode(fan)) == FanModeValue.manual
            var targetHeld = true
            if let target = targets[fan], let actual = port.read(FanKeys.target(fan)) {
                targetHeld = abs(actual - target) <= 1
            }
            if modeHeld, targetHeld {
                driftCounts[fan] = nil
                continue
            }
            let count = driftCounts[fan, default: 0] + 1
            driftCounts[fan] = count
            guard count <= timing.maxReasserts else {
                fault("Fan \(fan + 1) did not stay under manual control. macOS or another tool took it back, so fans went back to system control.")
                return
            }
            if !modeHeld { _ = writer.attempt(.fanMode(fan: fan, value: FanModeValue.manual)) }
            if let target = targets[fan] { _ = writer.attempt(.fanTarget(fan: fan, rpm: target)) }
        }
    }

    private func staleControllerReason(now: TimeInterval) -> String? {
        guard fanRequestIsActive || !manualFans.isEmpty else { return nil }
        if let disconnectedAt, now - disconnectedAt >= timing.disconnectGrace {
            return "The app disconnected, so fans went back to system control."
        }
        if let lastHeartbeat, now - lastHeartbeat >= timing.heartbeatTimeout {
            return "The app stopped responding, so fans went back to system control."
        }
        return nil
    }

    private static func controlValue(_ sensor: ControlSensor, readings: [SensorReading], summary: TemperatureSummary) -> Double? {
        let value: Double?
        switch sensor {
        case .cpuAverage: value = summary.cpuAverage
        case .cpuHottest: value = summary.cpuHottest
        case .gpu: value = summary.gpu
        case .ssd: value = summary.ssd
        case .battery: value = summary.battery
        case .hottest: value = summary.hottest
        case let .custom(ids, useAverage):
            let wanted = Set(ids)
            let values = readings.filter { wanted.contains($0.id.rawValue) }.map(\.value)
            guard !values.isEmpty else { return nil }
            value = useAverage ? values.reduce(0, +) / Double(values.count) : values.max()
        }
        guard let value, SensorCatalog.isPlausible(value, kind: .temperature) else { return nil }
        return value
    }

    // MARK: Fan writes

    /// Clamped here as well as in the curve math: this is the last stop before hardware. Invariant 5.
    /// Speed changes slew from where the fan is now. Only cooling that must not wait, such as Max, is immediate.
    private func command(fan: Int, rpm: Double, immediate: Bool = false) {
        guard !fanFaulted, let limits = inputs.fanLimits[fan], rpm.isFinite else { return }
        let clamped = min(max(rpm, limits.minimum), limits.maximum)
        if !manualFans.contains(fan) {
            guard enterManual(fan: fan) else { return }
        }
        let next = immediate ? clamped : slewed(fan: fan, toward: clamped, limits: limits)
        lastSlew[fan] = clockNow
        guard targets[fan] != next else { return }
        // Read-back is checked on the next tick by `verifyHeldFans`: on Mac16,8 a target can take over 150 ms to read
        // back as written, even though the fan obeys it. Failing here would hand back a fan that is working.
        _ = writer.attempt(.fanTarget(fan: fan, rpm: next))
        targets[fan] = next
    }

    private func slewed(fan: Int, toward target: Double, limits: FanLimits) -> Double {
        let actual = port.read(FanKeys.actual(fan)).map { min(max($0, limits.minimum), limits.maximum) }
        guard let current = targets[fan] ?? actual else { return target }
        let elapsed = min(max(clockNow - (lastSlew[fan] ?? clockNow - 1), 0), 1)
        let step = timing.slewPerSecond * elapsed
        return current + min(max(target - current, -step), step)
    }

    private func enterManual(fan: Int) -> Bool {
        var updated = journal
        if updated.originalUnlock == nil, port.info(KeyWhitelist.unlock) != nil, let unlock = port.read(KeyWhitelist.unlock) {
            updated.originalUnlock = unlock
        }
        guard let mode = port.read(FanKeys.mode(fan)) else {
            fault("Could not read the current fan mode, so fan control stopped.")
            return false
        }
        if updated.originalFanModes[fan] == nil { updated.originalFanModes[fan] = mode }
        // Unlocking changes the mode of every fan, so all are recorded while they still show their real values.
        for other in inputs.fanLimits.keys where updated.originalFanModes[other] == nil {
            if let value = port.read(FanKeys.mode(other)) { updated.originalFanModes[other] = value }
        }
        // The record reaches disk before the first write, so a crash right after it can still be undone.
        guard journalStore.save(updated) else {
            fault("Could not save the restore record, so fan control stopped.")
            return false
        }
        journal = updated
        if journal.originalUnlock != nil, port.read(KeyWhitelist.unlock) != 1 {
            // Once per tick, however many fans are waiting on it.
            if lastUnlockAttempt != clockNow {
                lastUnlockAttempt = clockNow
                _ = writer.attempt(.unlockFans(true))
            }
            if unlockRequestedAt == nil { unlockRequestedAt = clockNow }
            if port.read(KeyWhitelist.unlock) != 1 {
                return settleOrFault("Enabling manual fan control did not take effect.")
            }
        }
        guard writer.attempt(.fanMode(fan: fan, value: FanModeValue.manual)) else {
            return settleOrFault("The hardware refused manual mode on fan \(fan + 1).")
        }
        manualFans.insert(fan)
        // Another fan may still be refused for a moment, and gets its own window from here.
        unlockRequestedAt = clockNow
        return true
    }

    /// Refusals right after unlocking are normal, and the next tick tries again. Beyond the window, they are a failure.
    private func settleOrFault(_ message: String) -> Bool {
        let started = unlockRequestedAt ?? clockNow
        unlockRequestedAt = started
        if clockNow - started >= timing.unlockSettle {
            fault(message + " Fans went back to system control.")
        }
        return false
    }

    private func fault(_ message: String) {
        fanFaulted = true
        lastError = message
        releaseAllFans()
    }

    private func releaseAllFans() {
        for fan in journal.originalFanModes.keys.sorted() { returnToSystem(fan: fan) }
        finishFanRelease()
    }

    /// With an unlock key, the saved mode cannot be written back: on Mac16,8 the hardware refused `F0Md` = 3 while `Ftst`
    /// was 1. The working order is mode 0, then re-lock, after which the firmware manages the mode itself. Without an
    /// unlock key, the saved value is all there is. UNVERIFIED on other hardware.
    private func returnToSystem(fan: Int) {
        guard let original = journal.originalFanModes[fan] else { return }
        // A fan that is not in manual mode has nothing to hand back, and the hardware refuses the write anyway.
        if let mode = port.read(FanKeys.mode(fan)), mode != FanModeValue.manual {
            journal.originalFanModes[fan] = nil
            manualFans.remove(fan)
            targets[fan] = nil
            driftCounts[fan] = nil
            return
        }
        let value = journal.originalUnlock != nil ? FanModeValue.system : original
        if case .success = writer.perform(.fanMode(fan: fan, value: value)) {
            journal.originalFanModes[fan] = nil
            manualFans.remove(fan)
            targets[fan] = nil
            driftCounts[fan] = nil
        } else if releaseFailures >= timing.releaseFailuresBeforeMaximum / 2 {
            // Brief refusals are normal while hardware changes state, so only a lasting one is reported.
            lastError = "Fan \(fan + 1) did not confirm its return to system control. Retrying."
        }
    }

    /// Re-locks once no fan is manual, then clears the journal if nothing is left to undo. A fan that will not return
    /// must not stay at a low manual speed with nothing watching it, so after a few tries it goes to maximum.
    private func finishFanRelease() {
        guard journal.originalFanModes.isEmpty else {
            _ = journalStore.save(journal)
            releaseFailures += 1
            if releaseFailures >= timing.releaseFailuresBeforeMaximum { sendStuckFansToMaximum() }
            return
        }
        releaseFailures = 0
        unlockRequestedAt = nil
        if let unlock = journal.originalUnlock {
            // Reads back late as well, so the next tick's read is what confirms it.
            if port.read(KeyWhitelist.unlock) == unlock || writer.attempt(.unlockFans(unlock != 0)) {
                journal.originalUnlock = nil
            }
        }
        persistJournal()
    }

    private func sendStuckFansToMaximum() {
        for fan in journal.originalFanModes.keys.sorted() {
            guard let limits = inputs.fanLimits[fan], port.read(FanKeys.mode(fan)) == FanModeValue.manual, targets[fan] != limits.maximum else { continue }
            if case .success = writer.perform(.fanTarget(fan: fan, rpm: limits.maximum)) {
                targets[fan] = limits.maximum
                lastError = "Fan \(fan + 1) would not return to system control, so it was set to maximum for safety. Restart the Mac to clear this."
            }
        }
    }

    private func persistJournal() {
        if journal.isEmpty { journalStore.remove() } else { _ = journalStore.save(journal) }
    }

    private func restoreFromJournal() {
        manualFans.formUnion(journal.originalFanModes.keys)
        releaseAllFans()
        if journal.originalChargeValue != nil, writer.accepted(.chargeInhibit(value: 0)) {
            journal.originalChargeValue = nil
        }
        appliedCharge = .allowCharging
        chargeMachine = ChargeStateMachine()
        persistJournal()
    }

    // MARK: Charge

    private func tickCharge() {
        guard chargeCapability.isAvailable else { return }
        if chargeFaulted {
            // Keeps trying to reach the safe state, and writes nothing once it is there.
            applyChargeAction(.allowCharging)
            return
        }
        let battery = inputs.battery()
        // Battery telemetry can lag by about 35 s, so the check allows well over that.
        if appliedCharge != .allowCharging, battery.isCharging == true, clockNow - chargeChangedAt >= timing.inhibitEffectTimeout {
            chargeFailure("Charging did not stop as expected, so the charge limit was turned off.")
            applyChargeAction(.allowCharging)
            return
        }
        let wanted = chargeMachine.update(request: chargeRequest, inputs: battery, now: wallClock())
        if chargeMachine.topUpFinished {
            chargeRequest.topUp = false
            _ = chargeStore.save(chargeRequest)
        }
        if chargeMachine.pauseFinished {
            chargeRequest.pause = nil
            _ = chargeStore.save(chargeRequest)
        }
        applyChargeAction(wanted)
    }

    /// Only allow and inhibit are mapped to a key. Discharge has no key of its own yet, so it behaves as inhibit.
    /// `CHIE` does not echo what was written, so read-back cannot confirm it. The effect is checked in `tickCharge`.
    private func applyChargeAction(_ action: ChargeAction) {
        guard action != appliedCharge else { return }
        if action != .allowCharging, journal.originalChargeValue == nil {
            guard let original = port.read(KeyWhitelist.chargeInhibit) else {
                chargeFailure("Could not read the current charge state, so charging was left enabled.")
                return
            }
            journal.originalChargeValue = original
            guard journalStore.save(journal) else {
                journal.originalChargeValue = nil
                chargeFailure("Could not save the restore record, so charging was left enabled.")
                return
            }
        }
        // Back to 0, not to the saved value: firmware sets other bits briefly, such as 0x10 on plugging in.
        guard writer.accepted(.chargeInhibit(value: action == .allowCharging ? 0 : 1)) else {
            chargeFailure("The hardware refused to change the charge state.")
            return
        }
        appliedCharge = action
        chargeChangedAt = clockNow
        if action == .allowCharging {
            journal.originalChargeValue = nil
            persistJournal()
        }
    }

    private func chargeFailure(_ message: String) {
        chargeFaulted = true
        lastError = message
    }

    // MARK: Validation

    public enum RequestError: Error, Equatable, Sendable {
        case unavailable
        case unknownFan(Int)
        case invalidCurve(CurveError)
        case invalidPercent
        case storageFailed
    }

    /// Everything from the app is untrusted here, verified client or not.
    public static func validate(_ request: FanRequest, limits: [Int: FanLimits]) -> Result<FanRequest, RequestError> {
        for (fan, policy) in request.policies {
            guard limits[fan] != nil else { return .failure(.unknownFan(fan)) }
            switch policy {
            case let .constant(percent):
                guard percent.isFinite, (0...100).contains(percent) else { return .failure(.invalidPercent) }
            case let .curve(curve):
                if case let .failure(error) = CurveMath.validate(curve) { return .failure(.invalidCurve(error)) }
            case .system, .maximum:
                break
            }
        }
        return .success(request)
    }
}
