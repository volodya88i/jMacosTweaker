import Foundation

/// A four-character SMC key or type code.
public struct FourCC: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Creates a code from exactly four ASCII characters.
    public init?(string: String) {
        let bytes = Array(string.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        rawValue = bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// Literals are written by us in source. A malformed literal maps to zero, which no real key uses.
    public init(stringLiteral value: String) {
        self = FourCC(string: value) ?? FourCC(rawValue: 0)
    }

    public var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8((rawValue >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: Unicode.ASCII.self)
    }
}

public typealias SMCKey = FourCC

public struct SMCKeyInfo: Hashable, Sendable {
    public let size: Int
    public let type: FourCC
    public let attributes: UInt8

    public init(size: Int, type: FourCC, attributes: UInt8) {
        self.size = size
        self.type = type
        self.attributes = attributes
    }

    /// Bit 0x40 lines up with keys observed to be writable. A hint only. UNVERIFIED.
    public var hasWriteHint: Bool { attributes & 0x40 != 0 }
}

public struct SMCRawValue: Hashable, Sendable {
    public let info: SMCKeyInfo
    public let bytes: [UInt8]

    public init(info: SMCKeyInfo, bytes: [UInt8]) {
        self.info = info
        self.bytes = bytes
    }
}

public enum SMCError: Error, Equatable, Sendable {
    case serviceUnavailable
    case openFailed(Int32)
    case callFailed(Int32)
    case keyNotFound(String)
    case smcResult(UInt8)
    case undecodable(String)
}

/// Read-only SMC access. Writing lives only in the privileged helper target.
public protocol SMCReading: Sendable {
    func keyCount() throws(SMCError) -> Int
    func key(at index: Int) throws(SMCError) -> SMCKey
    func info(for key: SMCKey) throws(SMCError) -> SMCKeyInfo
    func read(_ key: SMCKey) throws(SMCError) -> SMCRawValue
}

public extension SMCReading {
    /// Reads and decodes a numeric key, or nil when it is absent or undecodable.
    func number(_ key: SMCKey) -> Double? {
        guard let raw = try? read(key) else { return nil }
        return SMCCodec.decodeNumber(raw, key: key)
    }

    func hasKey(_ key: SMCKey) -> Bool {
        (try? info(for: key)) != nil
    }
}
