import Foundation

public enum SensorKind: String, Codable, Hashable, Sendable {
    case temperature
    case voltage
    case current
    case power

    public var range: ClosedRange<Double> {
        switch self {
        case .temperature: 1...130
        case .voltage: 0.01...60
        case .current: 0.0001...100
        case .power: 0...1000
        }
    }

    public var unit: String {
        switch self {
        case .temperature: "°C"
        case .voltage: "V"
        case .current: "A"
        case .power: "W"
        }
    }
}

public enum SensorGroup: String, CaseIterable, Codable, Hashable, Sendable {
    case cpuPerformance
    case cpuEfficiency
    case gpu
    case soc
    case ssd
    case battery
    case enclosure
    case electrical
    case other

    /// True for the groups that make up "CPU" in summaries and fan control.
    public var isCPU: Bool { self == .cpuPerformance || self == .cpuEfficiency }
}

/// Stable identity. HID names repeat, so HID sensors use name plus ordinal.
public struct SensorID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func smc(_ key: SMCKey) -> SensorID { SensorID(rawValue: "smc:\(key)") }

    public static func hid(_ kind: SensorKind, identity: String) -> SensorID {
        SensorID(rawValue: "hid:\(kind.rawValue):\(identity)")
    }

    public var description: String { rawValue }
}

public struct SensorDescriptor: Hashable, Sendable, Identifiable {
    public let id: SensorID
    public let name: String
    public let group: SensorGroup
    public let kind: SensorKind

    public init(id: SensorID, name: String, group: SensorGroup, kind: SensorKind) {
        self.id = id
        self.name = name
        self.group = group
        self.kind = kind
    }
}

public struct SensorReading: Hashable, Sendable {
    public let id: SensorID
    public let value: Double

    public init(id: SensorID, value: Double) {
        self.id = id
        self.value = value
    }
}

/// Classification of sensors by name. Apple publishes none of this.
///
/// SMC families were identified on Mac16,8 by read-only load correlation (`tools/probes/thermal_correlation.sh`):
/// `Tp1`/`Tp2` rise most with CPU load, `Te` rises on E-core load, `Tg` rises most with GPU load. Elsewhere the
/// families are a best guess, so the raw key stays visible in every name and users can check for themselves.
public enum SensorCatalog {
    public static func group(smcKey key: String) -> SensorGroup {
        if key.hasPrefix("Tp1") || key.hasPrefix("Tp2") { return .cpuPerformance }
        if key.hasPrefix("Te0") { return .cpuEfficiency }
        if key.hasPrefix("Tg0") || key.hasPrefix("Tg1") { return .gpu }
        if key.hasPrefix("Tp0") || key.hasPrefix("Ts0") { return .soc }
        if key.hasPrefix("TB") { return .battery }
        if key.hasPrefix("Ta") { return .enclosure }
        return .other
    }

    public static func group(hidName name: String) -> SensorGroup {
        if name.hasPrefix("NAND") { return .ssd }
        if name.hasPrefix("gas gauge") { return .battery }
        if name.hasPrefix("PMU tdie") { return .soc }
        return .other
    }

    /// Aggregate keys such as `Tpx0` have unknown meaning and would double count, so only the numbered families and a
    /// few individually checked keys are offered.
    public static func isListedTemperatureKey(_ key: String) -> Bool {
        guard key.hasPrefix("T"), key.count == 4 else { return false }
        return group(smcKey: key) != .other || key.hasPrefix("TH0") || key == "TW0P"
    }

    public static func smcName(key: String, group: SensorGroup) -> String {
        let label: String
        switch group {
        case .cpuPerformance: label = "CPU P cluster"
        case .cpuEfficiency: label = "CPU E cluster"
        case .gpu: label = "GPU"
        case .soc: label = "SoC"
        case .battery: label = "Battery"
        case .enclosure: label = "Enclosure"
        default: label = "Sensor"
        }
        return "\(label) \(key)"
    }

    public static func isPlausible(_ value: Double, kind: SensorKind) -> Bool {
        value.isFinite && kind.range.contains(kind == .current ? abs(value) : value)
    }
}

/// Temperature figures the rest of the app cares about, derived from one set of readings.
public struct TemperatureSummary: Hashable, Sendable {
    public let cpuHottest: Double?
    public let cpuAverage: Double?
    public let gpu: Double?
    public let ssd: Double?
    public let battery: Double?

    public init(cpuHottest: Double?, cpuAverage: Double?, gpu: Double?, ssd: Double?, battery: Double?) {
        self.cpuHottest = cpuHottest
        self.cpuAverage = cpuAverage
        self.gpu = gpu
        self.ssd = ssd
        self.battery = battery
    }

    public static func make(readings: [SensorReading], groupOf: (SensorID) -> SensorGroup?) -> TemperatureSummary {
        var cpuSum = 0.0, cpuCount = 0.0
        var cpuMax: Double?, gpuMax: Double?, ssdMax: Double?, batteryMax: Double?
        for reading in readings {
            switch groupOf(reading.id) {
            case .cpuPerformance, .cpuEfficiency:
                cpuSum += reading.value
                cpuCount += 1
                cpuMax = Swift.max(cpuMax ?? reading.value, reading.value)
            case .gpu:
                gpuMax = Swift.max(gpuMax ?? reading.value, reading.value)
            case .ssd:
                ssdMax = Swift.max(ssdMax ?? reading.value, reading.value)
            case .battery:
                batteryMax = Swift.max(batteryMax ?? reading.value, reading.value)
            default:
                break
            }
        }
        return TemperatureSummary(
            cpuHottest: cpuMax,
            cpuAverage: cpuCount > 0 ? cpuSum / cpuCount : nil,
            gpu: gpuMax,
            ssd: ssdMax,
            battery: batteryMax
        )
    }

    /// Hottest of everything known, for the status line and the Temperature module.
    public var hottest: Double? {
        [cpuHottest, gpu, ssd, battery].compactMap { $0 }.max()
    }
}
