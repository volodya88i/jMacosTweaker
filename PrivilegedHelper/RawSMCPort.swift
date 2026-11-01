import Core
import Foundation
import HelperCore
import IOKit
import os

/// The only code in the project that can issue the SMC write command. It checks the whitelist itself, so a mistake
/// anywhere above still cannot reach another key.
final class RawSMCPort: SMCPort, @unchecked Sendable {
    private static let commandWriteBytes: UInt8 = 6
    private static let logger = Logger(subsystem: "com.jmacostweaker.helper", category: "writes")

    /// On while unverified control is allowed, so an on-device test leaves a record of every write.
    var logsWrites = false

    private let reader: SMCConnection
    private let connection: io_connect_t

    init() throws {
        reader = try SMCConnection()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceUnavailable }
        defer { IOObjectRelease(service) }
        var opened: io_connect_t = 0
        let status = IOServiceOpen(service, mach_task_self_, 0, &opened)
        guard status == KERN_SUCCESS else { throw SMCError.openFailed(status) }
        connection = opened
    }

    deinit {
        IOServiceClose(connection)
    }

    var smc: any SMCReading { reader }

    func info(_ key: SMCKey) -> SMCKeyInfo? {
        try? reader.info(for: key)
    }

    func read(_ key: SMCKey) -> Double? {
        reader.number(key)
    }

    func write(_ key: SMCKey, _ bytes: [UInt8]) -> Bool {
        guard KeyWhitelist.contains(key), let info = info(key), info.size == bytes.count, bytes.count <= 32 else { return false }
        var input = SMCKeyData()
        input.key = key.rawValue
        input.command = Self.commandWriteBytes
        input.keyInfo.dataSize = UInt32(info.size)
        withUnsafeMutableBytes(of: &input.bytes) { $0.copyBytes(from: bytes) }
        var output = SMCKeyData()
        var size = MemoryLayout<SMCKeyData>.stride
        let status = IOConnectCallStructMethod(
            connection, SMCKeyData.kernelSelector, &input, MemoryLayout<SMCKeyData>.stride, &output, &size
        )
        let accepted = status == KERN_SUCCESS && output.result == 0
        if logsWrites {
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            Self.logger.notice("write \(key.description, privacy: .public) \(hex, privacy: .public) accepted=\(accepted, privacy: .public)")
        }
        return accepted
    }
}
