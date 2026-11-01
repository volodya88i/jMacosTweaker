import Core
import Darwin
import Foundation
import HelperCore
import os
import Shared

private let logger = Logger(subsystem: "com.jmacostweaker.helper", category: "main")

private func hardwareModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
    return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
}

guard geteuid() == 0 else {
    logger.error("The helper must run as root under launchd.")
    exit(EX_NOPERM)
}

guard let port = try? RawSMCPort() else {
    // No SMC, for example in a VM. Nothing here can be controlled, and launchd must not restart it in a loop.
    logger.error("AppleSMC is not available. Exiting.")
    exit(0)
}

let inputs = RealInputs(smc: port.smc)
let model = hardwareModel()
let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
// Only the root-owned install script can create this file, and only when explicitly asked to, for a deliberate test.
let allowUnverified = FileManager.default.fileExists(atPath: HelperPaths.unverifiedFlagFile)

port.logsWrites = allowUnverified

let fanCapability = CapabilityProbe.fans(port: port, fanCount: inputs.fanLimits.count, model: model, osMajor: osMajor, allowUnverified: allowUnverified)
let chargeCapability = CapabilityProbe.charge(port: port, hasBattery: inputs.hasBattery, model: model, osMajor: osMajor, allowUnverified: allowUnverified)

let core = ControlCore(
    inputs: inputs,
    port: port,
    journalStore: FileStore(path: HelperPaths.journalFile),
    chargeStore: FileStore(path: HelperPaths.chargeFile),
    fanCapability: fanCapability,
    chargeCapability: chargeCapability
)

let pin = FileManager.default.contents(atPath: HelperPaths.pinFile).flatMap { try? JSONDecoder().decode(PinnedClient.self, from: $0) }
if pin == nil { logger.error("No pinned client. All connections will be refused.") }

HelperDaemon(core: core, pin: pin).run()
