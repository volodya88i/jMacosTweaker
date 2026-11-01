import Foundation

public enum SMCByteOrder: Sendable {
    case big
    case little

    /// Integer byte order by key family. The `B0*` family is little-endian despite its type name on Apple Silicon:
    /// B0CT 0x4800 reads 72 cycles, which matches `CycleCount`.
    public static func forIntegers(key: SMCKey) -> SMCByteOrder {
        (key.rawValue >> 16) == 0x4230 ? .little : .big
    }
}

/// Decoding and encoding of SMC values. Pure, so garbage input is cheap to test.
public enum SMCCodec {
    /// Decodes any numeric SMC type. Returns nil on a size mismatch, an unknown type or a non-finite float.
    public static func decodeNumber(_ raw: SMCRawValue, key: SMCKey) -> Double? {
        decodeNumber(bytes: raw.bytes, type: raw.info.type, order: SMCByteOrder.forIntegers(key: key))
    }

    public static func decodeNumber(bytes: [UInt8], type: FourCC, order: SMCByteOrder) -> Double? {
        let name = type.description
        switch name {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let value = Float32(bitPattern: littleEndianInteger(bytes))
            return value.isFinite ? Double(value) : nil
        case "ui8 ", "ui16", "ui32", "ui64":
            guard bytes.count == integerSize(name) else { return nil }
            return Double(integer(bytes, order: order))
        case "si8 ", "si16", "si32", "si64":
            guard bytes.count == integerSize(name) else { return nil }
            return Double(signExtended(integer(bytes, order: order), bytes: bytes.count))
        case "flag":
            guard bytes.count == 1 else { return nil }
            return bytes[0] == 0 ? 0 : 1
        case "hex_":
            // Only a single byte has an unambiguous numeric meaning. `CHIE` is one.
            guard bytes.count == 1 else { return nil }
            return Double(bytes[0])
        default:
            return decodeFixedPoint(bytes: bytes, name: name)
        }
    }

    /// Encodes a value for a writable key, or nil if the type is unknown or the value does not fit.
    public static func encode(_ value: Double, info: SMCKeyInfo, key: SMCKey) -> [UInt8]? {
        guard value.isFinite else { return nil }
        let name = info.type.description
        switch name {
        case "flt ":
            guard info.size == 4 else { return nil }
            let bits = Float32(value).bitPattern
            return [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8(bits >> 24)]
        case "ui8 ", "ui16", "ui32":
            guard info.size == integerSize(name), value >= 0, value == value.rounded() else { return nil }
            guard value < pow(2, Double(info.size * 8)) else { return nil }
            return integerBytes(UInt64(value), size: info.size, order: SMCByteOrder.forIntegers(key: key))
        case "flag":
            guard info.size == 1, value == 0 || value == 1 else { return nil }
            return [UInt8(value)]
        case "hex_":
            guard info.size == 1, value >= 0, value <= 255, value == value.rounded() else { return nil }
            return [UInt8(value)]
        default:
            return encodeFixedPoint(value, size: info.size, name: name)
        }
    }

    private static func integerSize(_ name: String) -> Int {
        switch name {
        case "ui8 ", "si8 ": 1
        case "ui16", "si16": 2
        case "ui32", "si32": 4
        default: 8
        }
    }

    private static func littleEndianInteger(_ bytes: [UInt8]) -> UInt32 {
        bytes.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func integer(_ bytes: [UInt8], order: SMCByteOrder) -> UInt64 {
        let ordered = order == .big ? bytes : bytes.reversed()
        return ordered.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func signExtended(_ value: UInt64, bytes: Int) -> Int64 {
        guard bytes < 8 else { return Int64(bitPattern: value) }
        let shift = UInt64(64 - bytes * 8)
        return Int64(bitPattern: value << shift) >> Int64(shift)
    }

    private static func integerBytes(_ value: UInt64, size: Int, order: SMCByteOrder) -> [UInt8] {
        let big = (0..<size).reversed().map { UInt8((value >> UInt64($0 * 8)) & 0xFF) }
        return order == .big ? big : big.reversed()
    }

    /// `fpXY` is unsigned and `spXY` signed big-endian fixed point, where Y is the fraction width in hex.
    private static func fractionBits(_ name: String) -> (signed: Bool, bits: Int)? {
        let chars = Array(name.utf8)
        guard chars.count == 4, chars[1] == UInt8(ascii: "p"),
              chars[0] == UInt8(ascii: "f") || chars[0] == UInt8(ascii: "s"),
              let bits = Int(String(decoding: chars[3...3], as: Unicode.ASCII.self), radix: 16) else { return nil }
        return (chars[0] == UInt8(ascii: "s"), bits)
    }

    private static func decodeFixedPoint(bytes: [UInt8], name: String) -> Double? {
        guard bytes.count == 2, let format = fractionBits(name) else { return nil }
        let value = integer(bytes, order: .big)
        let scale = pow(2, Double(format.bits))
        return format.signed ? Double(signExtended(value, bytes: 2)) / scale : Double(value) / scale
    }

    private static func encodeFixedPoint(_ value: Double, size: Int, name: String) -> [UInt8]? {
        guard size == 2, let format = fractionBits(name) else { return nil }
        let scaled = (value * pow(2, Double(format.bits))).rounded()
        if format.signed {
            guard scaled >= -32768, scaled <= 32767 else { return nil }
            return integerBytes(UInt64(UInt16(bitPattern: Int16(scaled))), size: 2, order: .big)
        }
        guard scaled >= 0, scaled <= 65535 else { return nil }
        return integerBytes(UInt64(scaled), size: 2, order: .big)
    }
}
