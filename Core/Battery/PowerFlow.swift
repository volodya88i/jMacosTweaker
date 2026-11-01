import Foundation

/// How power moves between adapter, system and battery, reconciled from one telemetry sample.
public enum PowerFlow: Hashable, Sendable {
    /// No adapter: the battery feeds the system.
    case onBattery(systemWatts: Double)
    /// The adapter covers the load and the rest charges the battery.
    case adapterCharging(adapterWatts: Double, systemWatts: Double, batteryWatts: Double)
    /// The adapter covers the load and the battery neither charges nor discharges meaningfully.
    case adapterOnly(adapterWatts: Double, systemWatts: Double)
    /// The adapter cannot cover the load, so the battery assists.
    case batteryAssist(adapterWatts: Double, systemWatts: Double, batteryWatts: Double)
    /// The numbers do not add up, or a field is missing. The UI shows N/A.
    case inconsistent
}

public enum PowerFlowMath {
    /// Battery power below this magnitude counts as idle.
    static let idleWatts = 0.25
    /// Allowed mismatch on top of reported losses: telemetry fields are not sampled at the same instant.
    static let absoluteTolerance = 2.0
    static let relativeTolerance = 0.12

    /// - Parameters:
    ///   - adapterWatts: power entering the system, zero or nil when unplugged.
    ///   - systemWatts: system load. Must be positive.
    ///   - batteryWatts: positive while charging, negative while discharging.
    ///   - lossWatts: reported adapter efficiency loss, if any.
    public static func reconcile(
        externalConnected: Bool,
        adapterWatts: Double?,
        systemWatts: Double?,
        batteryWatts: Double?,
        lossWatts: Double?
    ) -> PowerFlow {
        guard let system = systemWatts, system.isFinite, system >= 0, system < 1000 else { return .inconsistent }
        guard let battery = batteryWatts, battery.isFinite, abs(battery) < 500 else { return .inconsistent }

        guard externalConnected else {
            guard battery <= idleWatts, withinTolerance(-battery, system, extra: 0) else { return .inconsistent }
            return .onBattery(systemWatts: system)
        }

        guard let adapter = adapterWatts, adapter.isFinite, adapter >= 0, adapter < 1000 else { return .inconsistent }
        let loss = max(lossWatts ?? 0, 0)
        // For about 30 s after plugging in, telemetry still describes the unplugged state.
        guard adapter > idleWatts else { return .inconsistent }
        guard withinTolerance(adapter, system + battery, extra: loss) else { return .inconsistent }

        if battery > idleWatts {
            return .adapterCharging(adapterWatts: adapter, systemWatts: system, batteryWatts: battery)
        }
        if battery < -idleWatts {
            return .batteryAssist(adapterWatts: adapter, systemWatts: system, batteryWatts: -battery)
        }
        return .adapterOnly(adapterWatts: adapter, systemWatts: system)
    }

    private static func withinTolerance(_ left: Double, _ right: Double, extra: Double) -> Bool {
        let scale = max(abs(left), abs(right))
        return abs(left - right) <= absoluteTolerance + relativeTolerance * scale + extra
    }
}
