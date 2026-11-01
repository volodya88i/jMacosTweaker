import Core
import Foundation
import Shared

/// The raw writer, implemented only in the helper target. It reaches hardware only through `WritePlan` steps, and
/// refuses any key outside `KeyWhitelist`.
public protocol SMCPort: Sendable {
    func info(_ key: SMCKey) -> SMCKeyInfo?
    func read(_ key: SMCKey) -> Double?
    func write(_ key: SMCKey, _ bytes: [UInt8]) -> Bool
}

/// The only keys this software can ever write. A test fails if anything else is reachable.
public enum KeyWhitelist {
    public static let unlock: SMCKey = "Ftst"
    /// Candidate for charge inhibition. UNVERIFIED: the older keys do not exist on the tested Mac.
    public static let chargeInhibit: SMCKey = "CHIE"

    public static func contains(_ key: SMCKey) -> Bool {
        if key == unlock || key == chargeInhibit { return true }
        let name = Array(key.description.utf8)
        guard name.count == 4, name[0] == UInt8(ascii: "F"), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(name[1]) else { return false }
        let suffix = String(decoding: name[2...3], as: Unicode.ASCII.self)
        return suffix == "Md" || suffix == "Tg"
    }
}

/// Mode values seen working on Mac16,8. Other values, such as the 3 reported at rest, are refused or are firmware states.
public enum FanModeValue {
    public static let system = 0.0
    public static let manual = 1.0
}

/// Closed set of operations. There is no case that carries a key.
public enum ControlWrite: Equatable, Sendable {
    case unlockFans(Bool)
    case fanMode(fan: Int, value: Double)
    case fanTarget(fan: Int, rpm: Double)
    case chargeInhibit(value: Double)

    var key: SMCKey {
        switch self {
        case .unlockFans: KeyWhitelist.unlock
        case let .fanMode(fan, _): FanKeys.mode(fan)
        case let .fanTarget(fan, _): FanKeys.target(fan)
        case .chargeInhibit: KeyWhitelist.chargeInhibit
        }
    }

    var value: Double {
        switch self {
        case let .unlockFans(on): on ? 1 : 0
        case let .fanMode(_, value), let .fanTarget(_, value), let .chargeInhibit(value): value
        }
    }
}

public enum WriteError: Error, Equatable, Sendable {
    case notWhitelisted(String)
    case unknownKey(String)
    case unencodable(String)
    case rejected(String)
    case readbackMismatch(String)
}

/// Performs one write with read-back. Bounded retries, then the caller reverts. Invariants 1, 6 and 9.
public struct VerifiedWriter: Sendable {
    public static let maxAttempts = 3
    private let port: any SMCPort

    public init(port: any SMCPort) {
        self.port = port
    }

    public func perform(_ write: ControlWrite) -> Result<Void, WriteError> {
        let key = write.key
        guard KeyWhitelist.contains(key) else { return .failure(.notWhitelisted(key.description)) }
        guard let info = port.info(key) else { return .failure(.unknownKey(key.description)) }
        guard let bytes = SMCCodec.encode(write.value, info: info, key: key) else { return .failure(.unencodable(key.description)) }
        var failure = WriteError.rejected(key.description)
        for attempt in 0..<Self.maxAttempts {
            // A value can take a moment to read back as written: `Ftst` did on Mac16,8.
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.05) }
            guard port.write(key, bytes) else {
                failure = .rejected(key.description)
                continue
            }
            if let value = port.read(key), abs(value - write.value) <= Self.tolerance(write) { return .success(()) }
            failure = .readbackMismatch(key.description)
        }
        return .failure(failure)
    }

    /// One write and no retry, for steps that are expected to be refused while hardware changes state.
    /// The caller decides how long that is acceptable.
    public func attempt(_ write: ControlWrite) -> Bool {
        let key = write.key
        guard KeyWhitelist.contains(key), let info = port.info(key),
              let bytes = SMCCodec.encode(write.value, info: info, key: key), port.write(key, bytes),
              let value = port.read(key) else { return false }
        return abs(value - write.value) <= Self.tolerance(write)
    }

    /// Only whether the hardware accepted the write, for keys whose read-back does not echo the value.
    /// `CHIE` on Mac16,8 read 0 or 8 after writing 1. The caller must check the effect another way.
    public func accepted(_ write: ControlWrite) -> Bool {
        let key = write.key
        guard KeyWhitelist.contains(key), let info = port.info(key),
              let bytes = SMCCodec.encode(write.value, info: info, key: key) else { return false }
        return port.write(key, bytes)
    }

    private static func tolerance(_ write: ControlWrite) -> Double {
        if case .fanTarget = write { return 1 }
        return 0.001
    }
}

/// The record of what must be undone. Written before the first write that needs it. Invariant 7.
public struct RestoreJournal: Codable, Equatable, Sendable {
    /// Mode value each fan had before we touched it.
    public var originalFanModes: [Int: Double] = [:]
    public var originalUnlock: Double?
    public var originalChargeValue: Double?

    public init() {}

    public var isEmpty: Bool { originalFanModes.isEmpty && originalUnlock == nil && originalChargeValue == nil }
}

public protocol KeyValueStore: Sendable {
    func load<Value: Decodable>(_ type: Value.Type) -> Value?
    func save<Value: Encodable>(_ value: Value) -> Bool
    func remove()
}

/// Atomic JSON file, readable only by root.
public struct FileStore: KeyValueStore {
    private let path: String

    public init(path: String) {
        self.path = path
    }

    public func load<Value: Decodable>(_ type: Value.Type) -> Value? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public func save<Value: Encodable>(_ value: Value) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        return chmod(path, 0o600) == 0
    }

    public func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
