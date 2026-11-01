import Foundation
import IOKit

/// Reads `AppleSmartBattery`. Field locations verified on Mac16,8 with macOS 27.2: capacities are under `BatteryData`,
/// and the top-level `Temperature` is absent, so temperature comes from SMC `TB0T`.
/// On a 96 W adapter, `SystemPowerIn` equals `SystemLoad` + `BatteryPower` to within 0.1 W, and `Name` and `Watts` are
/// present. Telemetry refreshes about every 35 s. An inconsistent result shows as N/A.
public final class BatteryReader: BatteryReading, @unchecked Sendable {
    private let service: io_registry_entry_t
    private let smc: (any SMCReading)?

    public init?(smc: (any SMCReading)?) {
        let found = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard found != 0 else { return nil }
        service = found
        self.smc = smc
    }

    deinit {
        IOObjectRelease(service)
    }

    public var isPresent: Bool {
        (IORegistryEntryCreateCFProperty(service, "BatteryInstalled" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool) ?? false
    }

    public func sample() -> BatterySnapshot? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        return Self.parse(properties, temperature: smc?.number("TB0T"))
    }

    public static func parse(_ root: [String: Any], temperature: Double?) -> BatterySnapshot? {
        guard root["BatteryInstalled"] as? Bool ?? false else { return nil }
        let data = root["BatteryData"] as? [String: Any] ?? [:]
        let telemetry = root["PowerTelemetryData"] as? [String: Any] ?? [:]
        guard let percent = int(root["CurrentCapacity"]), (0...100).contains(percent) else { return nil }

        let external = root["ExternalConnected"] as? Bool ?? false
        let charging = root["IsCharging"] as? Bool ?? false
        let state: BatteryState = charging ? .charging : external ? .notCharging : .discharging
        let voltage = int(root["Voltage"]).map { Double($0) / 1000 }
        let amperage = int(root["InstantAmperage"] ?? root["Amperage"]).map { Double($0) / 1000 }

        return BatterySnapshot(
            percent: percent,
            state: state,
            externalConnected: external,
            fullyCharged: root["FullyCharged"] as? Bool ?? false,
            minutesToEmpty: minutes(root["AvgTimeToEmpty"]),
            minutesToFull: minutes(root["AvgTimeToFull"]),
            cycleCount: int(root["CycleCount"]),
            designCapacity: int(data["DesignCapacity"] ?? root["DesignCapacity"]),
            fullChargeCapacity: int(data["FullChargeCapacity"] ?? root["AppleRawMaxCapacity"]),
            voltage: voltage,
            amperage: amperage,
            temperature: temperature.flatMap { (-20...90).contains($0) ? $0 : nil },
            adapter: adapter(root["AdapterDetails"] as? [String: Any], external: external),
            flow: flow(external: external, telemetry: telemetry, data: data, voltage: voltage, amperage: amperage)
        )
    }

    private static func flow(
        external: Bool, telemetry: [String: Any], data: [String: Any], voltage: Double?, amperage: Double?
    ) -> PowerFlow {
        let instantBattery = voltage.flatMap { volts in amperage.map { volts * $0 } }
        return PowerFlowMath.reconcile(
            externalConnected: external,
            adapterWatts: milliwatts(telemetry["SystemPowerIn"]),
            systemWatts: milliwatts(telemetry["SystemLoad"]),
            batteryWatts: milliwatts(telemetry["BatteryPower"]) ?? instantBattery,
            lossWatts: milliwatts(telemetry["AdapterEfficiencyLoss"])
        )
    }

    private static func adapter(_ details: [String: Any]?, external: Bool) -> AdapterInfo? {
        guard external, let details else { return nil }
        let millivolts = int(details["AdapterVoltage"])
        return AdapterInfo(
            name: details["Name"] as? String,
            ratedWatts: int(details["Watts"]).map(Double.init),
            voltage: millivolts.map { Double($0) / 1000 }
        )
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func milliwatts(_ value: Any?) -> Double? {
        int(value).map { Double($0) / 1000 }
    }

    /// 65535 means "no estimate".
    private static func minutes(_ value: Any?) -> Int? {
        guard let minutes = int(value), minutes > 0, minutes < 65535 else { return nil }
        return minutes
    }
}
