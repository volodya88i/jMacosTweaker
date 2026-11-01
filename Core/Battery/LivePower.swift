import Foundation
import IOKit

/// A device the Mac is powering through a port, such as a phone charging from it.
public struct AccessoryPower: Hashable, Sendable, Identifiable {
    public let port: Int
    public let name: String?
    public let volts: Double
    public let amps: Double

    public var id: Int { port }
    public var watts: Double { volts * amps }

    public init(port: Int, name: String?, volts: Double, amps: Double) {
        self.port = port
        self.name = name
        self.volts = volts
        self.amps = amps
    }
}

public struct LivePowerSnapshot: Hashable, Sendable {
    public let flow: PowerFlow?
    public let accessories: [AccessoryPower]

    public init(flow: PowerFlow?, accessories: [AccessoryPower]) {
        self.flow = flow
        self.accessories = accessories
    }

    public var accessoryWatts: Double { accessories.reduce(0) { $0 + $1.watts } }

    /// The Mac's own share of system load. Accessories are powered from the same supply, so they are included in it.
    public var macWatts: Double? {
        guard let system = flow?.systemWatts else { return nil }
        return max(system - accessoryWatts, 0)
    }
}

public protocol LivePowerReading: Sendable {
    /// Nil when the keys are missing on this Mac. The slower battery telemetry is used then.
    func sample() -> LivePowerSnapshot?
}

public enum LivePowerMath {
    /// Battery telemetry refreshes about every 35 s. These SMC readings change every second.
    /// System load is what is left once the battery's share is taken out, so the figures add up by construction.
    /// `adapterPresent` has to come from elsewhere: `PDTR` read 6 to 7 W on battery with a phone charging from the Mac.
    public static func flow(adapterPresent: Bool, adapterWatts: Double, batteryVolts: Double, batteryAmps: Double) -> PowerFlow? {
        guard adapterWatts.isFinite, batteryVolts.isFinite, batteryAmps.isFinite,
              (0..<1000).contains(adapterWatts), (1..<100).contains(batteryVolts), abs(batteryAmps) < 50 else { return nil }
        let battery = batteryVolts * batteryAmps
        guard adapterPresent else {
            return battery < 0 ? .onBattery(systemWatts: -battery) : nil
        }
        let system = adapterWatts - battery
        guard system >= 0 else { return nil }
        return PowerFlowMath.reconcile(
            externalConnected: true, adapterWatts: adapterWatts, systemWatts: system, batteryWatts: battery, lossWatts: nil
        )
    }

    /// Plausible only if the port is sourcing and the readings are sane. Below this it is an idle connection.
    public static func accessory(port: Int, isSourcing: Bool, volts: Double, amps: Double, name: String?) -> AccessoryPower? {
        guard isSourcing, volts.isFinite, amps.isFinite, (1...50).contains(volts), (0.01...10).contains(amps) else { return nil }
        return AccessoryPower(port: port, name: name, volts: volts, amps: amps)
    }

    /// Minutes to reach `limit`, or nil unless charging below it. An estimate: charging slows as a battery fills.
    public static func minutesToLimit(percent: Int, limit: Int, fullCapacityMilliampHours: Int?, volts: Double?, batteryWatts: Double?) -> Int? {
        guard percent < limit, let capacity = fullCapacityMilliampHours, capacity > 0, let volts, volts > 0,
              let batteryWatts, batteryWatts > 0.5 else { return nil }
        let wattHours = Double(limit - percent) / 100 * Double(capacity) / 1000 * volts
        return max(Int((wattHours / batteryWatts * 60).rounded()), 1)
    }
}

/// Port keys verified on Mac16,8 with an iPhone charging on USB-C port 3: `D3JV` 5.21 V times `D3JI` 2.20 A gives 11.48 W,
/// and `AP3P` independently reads 11480 mW. `AP3S` reads 1 for that port and 0 for the adapter's. Numbering matches
/// `Port-USB-C@n`. Other accessory kinds, and other Macs, are not verified. Missing keys mean no rows.
public final class LivePowerReader: LivePowerReading, @unchecked Sendable {
    private let smc: any SMCReading
    private let ports: [Int]
    private let lock = NSLock()
    private var names: [Int: String] = [:]

    public init?(smc: any SMCReading) {
        guard smc.hasKey("PDTR"), smc.hasKey("B0AV"), smc.hasKey("B0AC"), smc.hasKey("AC-W") else { return nil }
        self.smc = smc
        ports = (1...4).filter { port in
            ["JV", "JI"].allSatisfy { suffix in SMCKey(string: "D\(port)\(suffix)").map(smc.hasKey) ?? false }
                && (SMCKey(string: "AP\(port)S").map(smc.hasKey) ?? false)
        }
    }

    public func sample() -> LivePowerSnapshot? {
        guard let adapter = smc.number("PDTR"), let millivolts = smc.number("B0AV"), let milliamps = smc.number("B0AC"),
              let presence = smc.number("AC-W") else { return nil }
        // `AC-W` read -1 with no adapter and 4 with the 96 W adapter.
        let flow = LivePowerMath.flow(adapterPresent: presence >= 0, adapterWatts: adapter, batteryVolts: millivolts / 1000, batteryAmps: milliamps / 1000)
        return LivePowerSnapshot(flow: flow, accessories: ports.compactMap(accessory))
    }

    private func accessory(port: Int) -> AccessoryPower? {
        guard let voltsKey = SMCKey(string: "D\(port)JV"), let ampsKey = SMCKey(string: "D\(port)JI"), let sourceKey = SMCKey(string: "AP\(port)S"),
              let volts = smc.number(voltsKey), let amps = smc.number(ampsKey), let source = smc.number(sourceKey) else { return nil }
        guard source == 1 else {
            lock.withLock { names[port] = nil }
            return nil
        }
        return LivePowerMath.accessory(port: port, isSourcing: true, volts: volts, amps: amps, name: name(ofPort: port))
    }

    /// Looked up once per connection, because it searches the registry.
    private func name(ofPort port: Int) -> String? {
        if let known = lock.withLock({ names[port] }) { return known.isEmpty ? nil : known }
        // All USB-C ports share one registry name, and `PortNumber` tells them apart.
        var iterator: io_iterator_t = 0
        var found: String?
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("Port-USB-C"), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                let number = IORegistryEntryCreateCFProperty(service, "PortNumber" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
                guard number?.intValue == port else { continue }
                let options = IOOptionBits(kIORegistryIterateRecursively)
                found = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "Product" as CFString, kCFAllocatorDefault, options) as? String
            }
        }
        // An unnamed device is remembered too, so the search does not repeat every second.
        lock.withLock { names[port] = found ?? "" }
        return found
    }
}
