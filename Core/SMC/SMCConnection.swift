import Foundation
import IOKit

/// The 80-byte structure AppleSMC expects. Swift places the next field after `size`, not `stride`, so `KeyInfo` needs
/// explicit trailing padding to match the C layout. `SMCLayoutTests` guards this: a wrong layout fails silently.
public struct SMCKeyData {
    public struct Version {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    public struct PowerLimit {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0
    }

    public struct KeyInfo {
        public var dataSize: UInt32 = 0
        public var dataType: UInt32 = 0
        public var dataAttributes: UInt8 = 0
        var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
    }

    public var key: UInt32 = 0
    var version = Version()
    var powerLimit = PowerLimit()
    public var keyInfo = KeyInfo()
    public var result: UInt8 = 0
    var status: UInt8 = 0
    public var command: UInt8 = 0
    public var index: UInt32 = 0
    public var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)

    public init() {}

    public static let kernelSelector: UInt32 = 2
    public static let commandReadBytes: UInt8 = 5
    public static let commandReadIndex: UInt8 = 8
    public static let commandReadInfo: UInt8 = 9
    public static let resultKeyNotFound: UInt8 = 0x84
}

/// Read-only connection to AppleSMC. Issues only the key info, key by index and read commands.
public final class SMCConnection: SMCReading, @unchecked Sendable {
    private let connection: io_connect_t
    private let lock = NSLock()
    private var infoCache: [SMCKey: SMCKeyInfo] = [:]

    public init() throws(SMCError) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw .serviceUnavailable }
        defer { IOObjectRelease(service) }
        var opened: io_connect_t = 0
        let status = IOServiceOpen(service, mach_task_self_, 0, &opened)
        guard status == KERN_SUCCESS else { throw .openFailed(status) }
        connection = opened
    }

    deinit {
        IOServiceClose(connection)
    }

    public func keyCount() throws(SMCError) -> Int {
        let raw = try read("#KEY")
        return raw.bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    public func key(at index: Int) throws(SMCError) -> SMCKey {
        var input = SMCKeyData()
        input.command = SMCKeyData.commandReadIndex
        input.index = UInt32(index)
        let output = try call(input, key: "index \(index)")
        return SMCKey(rawValue: output.key)
    }

    public func info(for key: SMCKey) throws(SMCError) -> SMCKeyInfo {
        if let cached = lock.withLock({ infoCache[key] }) { return cached }
        var input = SMCKeyData()
        input.key = key.rawValue
        input.command = SMCKeyData.commandReadInfo
        let output = try call(input, key: key.description)
        let info = SMCKeyInfo(
            size: Int(output.keyInfo.dataSize),
            type: FourCC(rawValue: output.keyInfo.dataType),
            attributes: output.keyInfo.dataAttributes
        )
        lock.withLock { infoCache[key] = info }
        return info
    }

    public func read(_ key: SMCKey) throws(SMCError) -> SMCRawValue {
        let info = try info(for: key)
        var input = SMCKeyData()
        input.key = key.rawValue
        input.command = SMCKeyData.commandReadBytes
        input.keyInfo.dataSize = UInt32(info.size)
        let output = try call(input, key: key.description)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(min(info.size, 32))) }
        return SMCRawValue(info: info, bytes: bytes)
    }

    private func call(_ input: SMCKeyData, key: String) throws(SMCError) -> SMCKeyData {
        var input = input
        var output = SMCKeyData()
        var size = MemoryLayout<SMCKeyData>.stride
        let status = IOConnectCallStructMethod(
            connection, SMCKeyData.kernelSelector, &input, MemoryLayout<SMCKeyData>.stride, &output, &size
        )
        guard status == KERN_SUCCESS else { throw .callFailed(status) }
        if output.result == SMCKeyData.resultKeyNotFound { throw .keyNotFound(key) }
        guard output.result == 0 else { throw .smcResult(output.result) }
        return output
    }
}
