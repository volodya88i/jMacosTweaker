@testable import Core
import XCTest

final class SMCCodecTests: XCTestCase {
    private func decode(_ bytes: [UInt8], _ type: FourCC, order: SMCByteOrder = .big) -> Double? {
        SMCCodec.decodeNumber(bytes: bytes, type: type, order: order)
    }

    func testStructLayoutMatchesKernel() {
        XCTAssertEqual(MemoryLayout<SMCKeyData>.stride, 80)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.keyInfo), 28)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.result), 40)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.command), 42)
        XCTAssertEqual(MemoryLayout<SMCKeyData>.offset(of: \.bytes), 48)
    }

    func testFourCCRoundTrip() {
        XCTAssertEqual(FourCC(string: "F0Ac")?.description, "F0Ac")
        XCTAssertNil(FourCC(string: "toolong"))
        XCTAssertNil(FourCC(string: "abc"))
        XCTAssertNil(FourCC(string: "ab\u{00e9}c"))
    }

    func testFloatIsLittleEndianAsObservedOnThisHardware() throws {
        // F0Mn reads 2317.0 on Mac16,8.
        let bits = Float32(2317).bitPattern
        let bytes = [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8(bits >> 24)]
        XCTAssertEqual(try XCTUnwrap(decode(bytes, "flt ")), 2317, accuracy: 0.001)
    }

    func testBatteryFamilyIntegersAreLittleEndian() {
        // B0CT 0x4800 means 72 cycles, which matches CycleCount.
        let info = SMCKeyInfo(size: 2, type: "ui16", attributes: 0)
        XCTAssertEqual(SMCCodec.decodeNumber(SMCRawValue(info: info, bytes: [0x48, 0x00]), key: "B0CT"), 72)
        XCTAssertEqual(SMCCodec.decodeNumber(SMCRawValue(info: info, bytes: [0x00, 0x48]), key: "XXCT"), 72)
    }

    func testSignedIntegers() {
        XCTAssertEqual(decode([0xFF], "si8 "), -1)
        XCTAssertEqual(decode([0xFF, 0xFE], "si16"), -2)
        XCTAssertEqual(decode([0xFD, 0x82], "si16", order: .little), -32003)
        XCTAssertEqual(decode([0xFF, 0xFF, 0xFF, 0xFF], "si32"), -1)
    }

    func testUnsignedIntegersAndFlag() {
        XCTAssertEqual(decode([200], "ui8 "), 200)
        XCTAssertEqual(decode([1, 0], "ui16"), 256)
        XCTAssertEqual(decode([0, 0, 1, 0], "ui32"), 256)
        XCTAssertEqual(decode([0, 0, 0, 0, 0, 0, 1, 0], "ui64"), 256)
        XCTAssertEqual(decode([1], "flag"), 1)
        XCTAssertEqual(decode([0], "flag"), 0)
    }

    func testFixedPoint() {
        XCTAssertEqual(decode([0x1F, 0x40], "fpe2"), 2000)
        XCTAssertEqual(decode([0x1A, 0x80], "sp78"), 26.5)
        XCTAssertEqual(decode([0xFF, 0x00], "sp78"), -1)
    }

    func testGarbageIsRejected() {
        XCTAssertNil(decode([], "flt "))
        XCTAssertNil(decode([1, 2, 3], "flt "))
        XCTAssertNil(decode([0, 0, 0xC0, 0x7F], "flt "), "NaN must not decode")
        XCTAssertNil(decode([0, 0, 0x80, 0x7F], "flt "), "Infinity must not decode")
        XCTAssertNil(decode([1, 2], "ui8 "))
        XCTAssertNil(decode([1, 2, 3, 4], "hex_"))
        XCTAssertNil(decode([1], "fpe2"))
        XCTAssertNil(decode([1, 2], "zzzz"))
    }

    func testEncodeRoundTrips() throws {
        let cases: [(FourCC, Int, Double)] = [("flt ", 4, 2317.5), ("ui8 ", 1, 3), ("ui16", 2, 500), ("ui32", 4, 70000), ("fpe2", 2, 2000), ("sp78", 2, -1.5), ("flag", 1, 1)]
        for (type, size, value) in cases {
            let info = SMCKeyInfo(size: size, type: type, attributes: 0)
            let bytes = try XCTUnwrap(SMCCodec.encode(value, info: info, key: "F0Tg"), "\(type)")
            let decoded = try XCTUnwrap(SMCCodec.decodeNumber(SMCRawValue(info: info, bytes: bytes), key: "F0Tg"))
            XCTAssertEqual(decoded, value, accuracy: 0.001, "\(type)")
        }
    }

    func testEncodeRefusesValuesThatDoNotFit() {
        let byte = SMCKeyInfo(size: 1, type: "ui8 ", attributes: 0)
        XCTAssertNil(SMCCodec.encode(256, info: byte, key: "F0Md"))
        XCTAssertNil(SMCCodec.encode(-1, info: byte, key: "F0Md"))
        XCTAssertNil(SMCCodec.encode(1.5, info: byte, key: "F0Md"))
        XCTAssertNil(SMCCodec.encode(.nan, info: SMCKeyInfo(size: 4, type: "flt ", attributes: 0), key: "F0Tg"))
        XCTAssertNil(SMCCodec.encode(2, info: SMCKeyInfo(size: 1, type: "flag", attributes: 0), key: "Ftst"))
        XCTAssertNil(SMCCodec.encode(1, info: SMCKeyInfo(size: 4, type: "hex_", attributes: 0), key: "CHIE"))
        XCTAssertNil(SMCCodec.encode(100_000, info: SMCKeyInfo(size: 2, type: "fpe2", attributes: 0), key: "F0Tg"))
    }

    func testSingleByteHexAsObservedOnCHIE() {
        let info = SMCKeyInfo(size: 1, type: "hex_", attributes: 0xD4)
        XCTAssertEqual(SMCCodec.decodeNumber(SMCRawValue(info: info, bytes: [0]), key: "CHIE"), 0)
        XCTAssertEqual(SMCCodec.encode(1, info: info, key: "CHIE"), [1])
        XCTAssertNil(SMCCodec.encode(256, info: info, key: "CHIE"))
        XCTAssertNil(SMCCodec.encode(0.5, info: info, key: "CHIE"))
    }

    func testWriteHint() {
        XCTAssertTrue(SMCKeyInfo(size: 1, type: "ui8 ", attributes: 0xD0).hasWriteHint)
        XCTAssertFalse(SMCKeyInfo(size: 1, type: "ui8 ", attributes: 0x84).hasWriteHint)
    }
}
