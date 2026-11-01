import Foundation

public enum BatteryState: String, Hashable, Sendable {
    case charging
    case discharging
    /// On adapter and not charging: full, held at a limit, or paused by the system.
    case notCharging
}

public struct AdapterInfo: Hashable, Sendable {
    public let name: String?
    public let ratedWatts: Double?
    public let voltage: Double?

    public init(name: String?, ratedWatts: Double?, voltage: Double?) {
        self.name = name
        self.ratedWatts = ratedWatts
        self.voltage = voltage
    }
}

public struct BatterySnapshot: Hashable, Sendable {
    public let percent: Int
    public let state: BatteryState
    public let externalConnected: Bool
    public let fullyCharged: Bool
    /// Minutes, nil when the system has no estimate.
    public let minutesToEmpty: Int?
    public let minutesToFull: Int?
    public let cycleCount: Int?
    public let designCapacity: Int?
    public let fullChargeCapacity: Int?
    public let voltage: Double?
    public let amperage: Double?
    public let temperature: Double?
    public let adapter: AdapterInfo?
    public let flow: PowerFlow

    public init(
        percent: Int, state: BatteryState, externalConnected: Bool, fullyCharged: Bool, minutesToEmpty: Int?,
        minutesToFull: Int?, cycleCount: Int?, designCapacity: Int?, fullChargeCapacity: Int?, voltage: Double?,
        amperage: Double?, temperature: Double?, adapter: AdapterInfo?, flow: PowerFlow
    ) {
        self.percent = percent
        self.state = state
        self.externalConnected = externalConnected
        self.fullyCharged = fullyCharged
        self.minutesToEmpty = minutesToEmpty
        self.minutesToFull = minutesToFull
        self.cycleCount = cycleCount
        self.designCapacity = designCapacity
        self.fullChargeCapacity = fullChargeCapacity
        self.voltage = voltage
        self.amperage = amperage
        self.temperature = temperature
        self.adapter = adapter
        self.flow = flow
    }

    /// Full charge capacity over design capacity. Labeled in the UI as a capacity ratio, because the figure System
    /// Settings shows may be derived differently (UNVERIFIED).
    public var health: Double? {
        guard let design = designCapacity, design > 0, let full = fullChargeCapacity, full > 0 else { return nil }
        return Double(full) / Double(design)
    }

    /// Battery terminal power. Positive while charging.
    public var batteryWatts: Double? {
        guard let voltage, let amperage else { return nil }
        return voltage * amperage
    }

    public var systemWatts: Double? { flow.systemWatts }
}

public extension PowerFlow {
    /// System load in watts when it can be stated consistently.
    var systemWatts: Double? {
        switch self {
        case let .onBattery(system), let .adapterOnly(_, system):
            system
        case let .adapterCharging(_, system, _), let .batteryAssist(_, system, _):
            system
        case .inconsistent:
            nil
        }
    }

    /// Watts going into the battery, when charging.
    var chargingWatts: Double? {
        if case let .adapterCharging(_, _, battery) = self { return battery }
        return nil
    }
}

public protocol BatteryReading: Sendable {
    /// Nil on Macs with no battery.
    func sample() -> BatterySnapshot?
    var isPresent: Bool { get }
}
