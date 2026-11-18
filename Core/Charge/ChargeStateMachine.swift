import Foundation
import Shared

public struct ChargeInputs: Sendable, Equatable {
    /// Nil means battery state could not be read. That always enables charging.
    public var percent: Int?
    public var temperature: Double?
    public var externalConnected: Bool
    /// Whether the battery reports charging. Used to check that inhibition really took effect.
    public var isCharging: Bool?

    public init(percent: Int?, temperature: Double?, externalConnected: Bool, isCharging: Bool? = nil) {
        self.percent = percent
        self.temperature = temperature
        self.externalConnected = externalConnected
        self.isCharging = isCharging
    }
}

/// Decides what charging should do. Pure, and run by the helper, so limits keep working with the app closed.
public struct ChargeStateMachine: Sendable {
    /// Never inhibit at or below this. Not configurable.
    public static let safeFloor = 20
    public static let limitRange = 50...100
    public static let sailingRange = 1...20
    /// Lowest level a pause may run down to. The safe floor ends it earlier if this were ever lower.
    public static let pauseLevelRange = 20...95
    /// Longest pause the helper accepts. A forgotten pause must not drain a battery for days on the adapter.
    public static let longestPause: TimeInterval = 24 * 3600
    static let heatRecovery = 3.0

    public private(set) var action = ChargeAction.allowCharging
    private var holding = false
    private var heatPaused = false
    /// Set when a top-up finishes, so the app can clear it.
    public private(set) var topUpFinished = false
    /// Set when a pause reaches its time, its level or the floor, so the helper can clear it.
    public private(set) var pauseFinished = false

    public init() {}

    public static func clamped(_ request: ChargeRequest) -> ChargeRequest {
        var result = request
        result.limit = min(max(request.limit, limitRange.lowerBound), limitRange.upperBound)
        result.sailing = min(max(request.sailing, sailingRange.lowerBound), sailingRange.upperBound)
        result.heatLimit = request.heatLimit.isFinite ? min(max(request.heatLimit, 30), 50) : 40
        if var pause = request.pause {
            pause.untilPercent = pause.untilPercent.map { min(max($0, pauseLevelRange.lowerBound), pauseLevelRange.upperBound) }
            // A pause with no end is refused rather than guessed at.
            result.pause = pause.until == nil && pause.untilPercent == nil ? nil : pause
        }
        return result
    }

    /// The request as the helper will run it: clamped, and every pause ending no later than `longestPause` from now,
    /// even one that only names a level.
    public static func validated(_ request: ChargeRequest, now: Date) -> ChargeRequest {
        var result = clamped(request)
        guard var pause = result.pause else { return result }
        let latest = now.addingTimeInterval(longestPause)
        pause.until = min(pause.until ?? latest, latest)
        result.pause = pause
        return result
    }

    @discardableResult
    public mutating func update(request raw: ChargeRequest, inputs: ChargeInputs, now: Date = Date()) -> ChargeAction {
        action = evaluate(request: Self.clamped(raw), inputs: inputs, now: now)
        return action
    }

    private mutating func evaluate(request: ChargeRequest, inputs: ChargeInputs, now: Date) -> ChargeAction {
        topUpFinished = false
        pauseFinished = false
        guard let percent = inputs.percent, (0...100).contains(percent) else {
            reset()
            return .allowCharging
        }
        if percent <= Self.safeFloor {
            if request.pause != nil { pauseFinished = true }
            reset()
            return .allowCharging
        }
        if let pause = request.pause {
            let timeUp = pause.until.map { now >= $0 } ?? false
            let levelReached = pause.untilPercent.map { percent <= $0 } ?? false
            if timeUp || levelReached {
                // Ends here, and the normal policy below takes over in the same evaluation.
                pauseFinished = true
            } else {
                reset()
                return .dischargeOnAdapter
            }
        }
        guard request.enabled else {
            reset()
            return .allowCharging
        }
        if request.topUp {
            reset()
            if percent >= 100 { topUpFinished = true }
            return .allowCharging
        }

        updateHeat(request: request, temperature: inputs.temperature)

        if request.dischargeToLimit, inputs.externalConnected, percent > request.limit {
            holding = true
            return .dischargeOnAdapter
        }

        if percent >= request.limit {
            holding = true
        } else if percent <= request.limit - request.sailing {
            holding = false
        }
        return holding || heatPaused ? .inhibitCharging : .allowCharging
    }

    private mutating func updateHeat(request: ChargeRequest, temperature: Double?) {
        guard request.heatProtection, let temperature, temperature.isFinite else {
            heatPaused = false
            return
        }
        if temperature >= request.heatLimit {
            heatPaused = true
        } else if temperature <= request.heatLimit - Self.heatRecovery {
            heatPaused = false
        }
    }

    private mutating func reset() {
        holding = false
        heatPaused = false
    }
}
