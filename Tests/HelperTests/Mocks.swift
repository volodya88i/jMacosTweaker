import Core
import Foundation
@testable import HelperCore
import Shared

/// Simulated SMC. Records every write, and can reject writes or ignore them to fake read-back failures.
final class MockPort: SMCPort, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SMCKey: Double]
    private var infos: [SMCKey: SMCKeyInfo]
    private(set) var writes: [(key: SMCKey, value: Double)] = []
    var rejectAll = false
    var ignoreWrites = false
    var rejectKeys: Set<SMCKey> = []
    var unreadableKeys: Set<SMCKey> = []
    /// As seen on Mac16,8: mode 3 is refused while unlocked, and re-locking turns mode 0 into 3.
    var observedFirmware = true
    /// As seen on Mac16,8: for this many `firmwareTick` calls after unlocking, `Ftst` reads old and mode writes are refused.
    var unlockDelayTicks = 0
    private var unlockDelayLeft = 0
    private var pendingUnlock: Double?

    func firmwareTick() {
        lock.withLock {
            guard unlockDelayLeft > 0 else { return }
            unlockDelayLeft -= 1
            if unlockDelayLeft == 0, let pendingUnlock {
                values[KeyWhitelist.unlock] = pendingUnlock
                self.pendingUnlock = nil
            }
        }
    }

    init(fans: Int = 2, mode: Double = 3, withCharge: Bool = true, withUnlock: Bool = true) {
        var values: [SMCKey: Double] = [:]
        var infos: [SMCKey: SMCKeyInfo] = [:]
        for fan in 0..<fans {
            values[FanKeys.mode(fan)] = mode
            infos[FanKeys.mode(fan)] = SMCKeyInfo(size: 1, type: "ui8 ", attributes: 0xD0)
            values[FanKeys.target(fan)] = 0
            infos[FanKeys.target(fan)] = SMCKeyInfo(size: 4, type: "flt ", attributes: 0xD4)
        }
        if withUnlock {
            values[KeyWhitelist.unlock] = 0
            infos[KeyWhitelist.unlock] = SMCKeyInfo(size: 1, type: "ui8 ", attributes: 0xD0)
        }
        if withCharge {
            values[KeyWhitelist.chargeInhibit] = 0
            infos[KeyWhitelist.chargeInhibit] = SMCKeyInfo(size: 1, type: "ui8 ", attributes: 0xD0)
        }
        self.values = values
        self.infos = infos
    }

    func info(_ key: SMCKey) -> SMCKeyInfo? { lock.withLock { infos[key] } }

    func read(_ key: SMCKey) -> Double? {
        lock.withLock {
            if unreadableKeys.contains(key) { return nil }
            return lateValues[key] ?? values[key]
        }
    }

    /// As seen on Mac16,8: a written target can read back its old value for a while.
    var lateTargets = false
    private var lateValues: [SMCKey: Double] = [:]

    func settleLateValues() {
        lock.withLock { lateValues.removeAll() }
    }

    /// Changes a value behind the helper's back, like firmware or another tool.
    func externallySet(_ key: SMCKey, _ value: Double) {
        lock.withLock { values[key] = value }
    }

    func value(_ key: SMCKey) -> Double? { lock.withLock { values[key] } }

    func write(_ key: SMCKey, _ bytes: [UInt8]) -> Bool {
        lock.withLock {
            guard let info = infos[key], !rejectAll, !rejectKeys.contains(key) else { return false }
            let value = SMCCodec.decodeNumber(SMCRawValue(info: info, bytes: bytes), key: key) ?? .nan
            writes.append((key, value))
            if observedFirmware, key.description.hasSuffix("Md"), value == 3, values[KeyWhitelist.unlock] == 1 {
                return false
            }
            if key.description.hasSuffix("Md"), unlockDelayLeft > 0 { return false }
            if key == KeyWhitelist.unlock, value == 1, unlockDelayTicks > 0, values[key] != 1 {
                if unlockDelayLeft == 0 { unlockDelayLeft = unlockDelayTicks }
                pendingUnlock = 1
                return true
            }
            if lateTargets, key.description.hasSuffix("Tg"), lateValues[key] == nil { lateValues[key] = values[key] }
            if !ignoreWrites { values[key] = value }
            if observedFirmware, key == KeyWhitelist.unlock, value == 0 {
                for candidate in values.keys where candidate.description.hasSuffix("Md") && values[candidate] == 0 {
                    values[candidate] = 3
                }
            }
            return true
        }
    }

    func clearWrites() { lock.withLock { writes.removeAll() } }
}

final class MemoryStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    var data: Data?
    var failSaves = false
    func load<Value: Decodable>(_ type: Value.Type) -> Value? {
        lock.withLock { data.flatMap { try? JSONDecoder().decode(type, from: $0) } }
    }
    func save<Value: Encodable>(_ value: Value) -> Bool {
        lock.withLock {
            guard !failSaves else { return false }
            data = try? JSONEncoder().encode(value)
            return true
        }
    }
    func remove() { lock.withLock { data = nil } }
}

final class MockInputs: ControlInputs, @unchecked Sendable {
    var fanLimits: [Int: FanLimits] = [0: FanLimits(minimum: 2317, maximum: 7826), 1: FanLimits(minimum: 2317, maximum: 7826)]
    var cpu: Double? = 50
    var gpu: Double? = 40
    var ssd: Double? = 30
    var batteryTemperature: Double? = 25
    var percent: Int? = 60
    var external = true
    var isCharging: Bool?

    private(set) var readingCalls = 0

    func readings(full: Bool) -> [SensorReading] {
        readingCalls += 1
        return cpu.map { [SensorReading(id: .smc("Tp1a"), value: $0)] } ?? []
    }

    func summary(_ readings: [SensorReading]) -> TemperatureSummary {
        TemperatureSummary(cpuHottest: cpu, cpuAverage: cpu, gpu: gpu, ssd: ssd, battery: batteryTemperature)
    }

    func battery() -> ChargeInputs {
        ChargeInputs(percent: percent, temperature: batteryTemperature, externalConnected: external, isCharging: isCharging)
    }
}

let balancedCurve = FanCurve(points: [.init(temperature: 40, percent: 0), .init(temperature: 80, percent: 100)])

func allFans(_ policy: FanPolicy) -> FanRequest {
    FanRequest(policies: [0: policy, 1: policy], sensor: .cpuHottest)
}

func makeCore(
    port: MockPort = MockPort(), inputs: MockInputs = MockInputs(), journal: MemoryStore = MemoryStore(), charge: MemoryStore = MemoryStore(),
    fanCapability: Capability = .available, chargeCapability: Capability = .available
) -> ControlCore {
    ControlCore(inputs: inputs, port: port, journalStore: journal, chargeStore: charge, fanCapability: fanCapability, chargeCapability: chargeCapability)
}
