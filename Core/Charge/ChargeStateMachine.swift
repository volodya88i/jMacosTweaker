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
    static let heatRecovery = 3.0

    public private(set) var action = ChargeAction.allowCharging
    private var holding = false
    private var heatPaused = false
    /// Set when a top-up finishes, so the app can clear it.
    public private(set) var topUpFinished = false

    public init() {}

    public static func clamped(_ request: ChargeRequest) -> ChargeRequest {
        var result = request
        result.limit = min(max(request.limit, limitRange.lowerBound), limitRange.upperBound)
        result.sailing = min(max(request.sailing, sailingRange.lowerBound), sailingRange.upperBound)
        result.heatLimit = request.heatLimit.isFinite ? min(max(request.heatLimit, 30), 50) : 40
        return result
    }

    @discardableResult
    public mutating func update(request raw: ChargeRequest, inputs: ChargeInputs) -> ChargeAction {
        action = evaluate(request: Self.clamped(raw), inputs: inputs)
        return action
    }

    private mutating func evaluate(request: ChargeRequest, inputs: ChargeInputs) -> ChargeAction {
        topUpFinished = false
        guard request.enabled, let percent = inputs.percent, (0...100).contains(percent) else {
            reset()
            return .allowCharging
        }
        if percent <= Self.safeFloor {
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
