import Core
import Foundation
import HelperCore
import IOKit
import IOKit.pwr_mgt
import os
import Shared

/// Owns the listener and the control loop. All state goes through one serial queue. The loop timer exists only while
/// something is being controlled, so an idle helper does nothing at all.
final class HelperDaemon: NSObject, NSXPCListenerDelegate, HelperXPC, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.jmacostweaker.helper", category: "daemon")
    private static let maxPayload = 64 * 1024

    // IOMessage.h defines these as macros, which Swift does not import.
    private static let messageCanSystemSleep: natural_t = 0xE000_0270
    private static let messageSystemWillSleep: natural_t = 0xE000_0280
    private static let messageSystemHasPoweredOn: natural_t = 0xE000_0300

    private let queue = DispatchQueue(label: "com.jmacostweaker.helper.control")
    private let core: ControlCore
    private let pin: PinnedClient?
    private let listener = NSXPCListener(machServiceName: helperMachServiceName)
    private var timer: (any DispatchSourceTimer)?
    private var connections = 0
    private var powerPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var rootPowerConnection: io_connect_t = 0
    private var signalSource: (any DispatchSourceSignal)?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(core: ControlCore, pin: PinnedClient?) {
        self.core = core
        self.pin = pin
        super.init()
    }

    func run() -> Never {
        queue.sync {
            core.start()
            Self.logger.notice("Startup restore finished, \(ProcessInfo.processInfo.systemUptime, privacy: .public) s after boot")
            rearm()
        }
        listener.delegate = self
        listener.resume()
        Self.logger.notice("Listening, \(ProcessInfo.processInfo.systemUptime, privacy: .public) s after boot")
        registerForPower()
        handleTermination()
        dispatchMain()
    }

    // MARK: Connections

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let token = Self.auditToken(of: connection) else { return false }
        let identity = CodeInspector.identity(auditToken: token)
        if let rejection = ClientVerifier.check(identity: identity, pin: pin) {
            Self.logger.error("Rejected a client: \(String(describing: rejection), privacy: .public)")
            return false
        }
        // Enforced by the system on every message, in addition to the check above.
        if let pin { connection.setCodeSigningRequirement("cdhash H\"\(pin.cdhash)\"") }
        connection.exportedInterface = NSXPCInterface(with: HelperXPC.self)
        connection.exportedObject = self
        let closed: @Sendable () -> Void = { [weak self] in self?.connectionClosed() }
        connection.invalidationHandler = closed
        connection.resume()
        queue.async {
            self.connections += 1
            self.core.clientConnected(now: self.now)
        }
        return true
    }

    private func connectionClosed() {
        queue.async {
            self.connections = max(self.connections - 1, 0)
            if self.connections == 0 {
                self.core.clientDisconnected(now: self.now)
                self.rearm()
            }
        }
    }

    /// The token is not public API on `NSXPCConnection`. Without it, the connection is refused.
    private static func auditToken(of connection: NSXPCConnection) -> audit_token_t? {
        guard let value = connection.value(forKey: "auditToken") as? NSValue else { return nil }
        var token = audit_token_t()
        value.getValue(&token, size: MemoryLayout<audit_token_t>.size)
        return token
    }

    // MARK: HelperXPC

    func status(reply: @escaping @Sendable (Data?) -> Void) {
        queue.async { reply(self.encodedReply(error: nil)) }
    }

    func heartbeat() {
        queue.async { self.core.heartbeat(now: self.now) }
    }

    func applyFans(_ request: Data, reply: @escaping @Sendable (Data?) -> Void) {
        queue.async {
            guard request.count <= Self.maxPayload, let decoded = try? JSONDecoder().decode(FanRequest.self, from: request) else {
                reply(self.encodedReply(error: "The request could not be read."))
                return
            }
            if decoded.policies.values.contains(where: { $0 != .system }), let tool = self.blocker(.fans) {
                reply(self.encodedReply(error: "The background helper of \(tool.name) is running. Stop it before using fan control."))
                return
            }
            let result = self.core.applyFans(decoded, now: self.now)
            self.rearm()
            reply(self.encodedReply(error: Self.message(result)))
        }
    }

    func applyCharge(_ request: Data, reply: @escaping @Sendable (Data?) -> Void) {
        queue.async {
            guard request.count <= Self.maxPayload, let decoded = try? JSONDecoder().decode(ChargeRequest.self, from: request) else {
                reply(self.encodedReply(error: "The request could not be read."))
                return
            }
            if decoded.enabled, let tool = self.blocker(.charging) {
                reply(self.encodedReply(error: "The background helper of \(tool.name) is running. Stop it before using the charge limit."))
                return
            }
            let result = self.core.applyCharge(decoded, now: self.now)
            self.rearm()
            reply(self.encodedReply(error: Self.message(result)))
        }
    }

    func restoreDefaults(reply: @escaping @Sendable (Data?) -> Void) {
        queue.async {
            self.core.restoreDefaults()
            self.rearm()
            reply(self.encodedReply(error: nil))
        }
    }

    private func blocker(_ area: ControlArea) -> KnownTool? {
        ConflictDetector.blocker(in: ConflictDetector.detect(), area: area)
    }

    private static func message(_ result: Result<Void, ControlCore.RequestError>) -> String? {
        guard case let .failure(error) = result else { return nil }
        switch error {
        case .unavailable: return "This control is not available on this Mac."
        case let .unknownFan(fan): return "Fan \(fan + 1) does not exist."
        case .invalidCurve: return "The curve is not valid."
        case .invalidPercent: return "The speed is out of range."
        case .storageFailed: return "The setting could not be saved."
        }
    }

    private func encodedReply(error: String?) -> Data? {
        try? JSONEncoder().encode(HelperReply(status: core.status(protocolVersion: helperProtocolVersion), error: error))
    }

    // MARK: Loop

    private func rearm() {
        if core.needsTimer {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let previous = self.core.lastError
                self.core.tick(now: self.now)
                if let error = self.core.lastError, error != previous {
                    Self.logger.error("\(error, privacy: .public)")
                }
                self.rearm()
            }
            source.resume()
            timer = source
        } else {
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: Power and exit

    private func registerForPower() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPowerConnection = IORegisterForSystemPower(context, &powerPort, { context, _, message, argument in
            guard let context else { return }
            let daemon = Unmanaged<HelperDaemon>.fromOpaque(context).takeUnretainedValue()
            daemon.powerEvent(message: message, argument: argument)
        }, &powerNotifier)
        if let powerPort { IONotificationPortSetDispatchQueue(powerPort, queue) }
    }

    /// Runs on `queue`. Sleep is acknowledged only after fans are back under system control.
    private func powerEvent(message: natural_t, argument: UnsafeMutableRawPointer?) {
        switch message {
        case Self.messageSystemWillSleep:
            core.willSleep()
            rearm()
            Self.logger.notice("Sleep: fans under control after hand-back: \(self.core.status(protocolVersion: helperProtocolVersion).fansUnderControl.count, privacy: .public)")
            IOAllowPowerChange(rootPowerConnection, Int(bitPattern: argument))
        case Self.messageCanSystemSleep:
            IOAllowPowerChange(rootPowerConnection, Int(bitPattern: argument))
        case Self.messageSystemHasPoweredOn:
            core.didWake(now: now)
            rearm()
            Self.logger.notice("Wake: control evaluated")
        default:
            break
        }
    }

    /// `launchctl bootout`, uninstall and shutdown all send SIGTERM.
    private func handleTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        source.setEventHandler { [weak self] in
            self?.core.prepareForExit()
            exit(0)
        }
        source.resume()
        signalSource = source
    }
}
