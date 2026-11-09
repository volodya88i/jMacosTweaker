import Foundation
import Observation
import Security
import Shared

enum HelperState: Equatable {
    case checking
    case notInstalled
    /// Installed for a different build of the app, so the helper would refuse it.
    case needsRepin
    /// This app is not the installed copy in /Applications.
    case notInstalledCopy
    case outdated
    case notResponding
    case running
}

/// The app's only route to privileged actions. It sends intent. All decisions stay in the helper.
@MainActor
@Observable
final class HelperClient {
    private(set) var state = HelperState.checking
    private(set) var status: HelperStatus?
    private(set) var lastError: String?

    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var activity: (any NSObjectProtocol)?
    @ObservationIgnored private var missedBeats = 0
    private static let maxMissedBeats = 6

    private func proxy(onError: @escaping @Sendable (any Error) -> Void) -> (any HelperXPC)? {
        let active: NSXPCConnection
        if let connection {
            active = connection
        } else {
            active = NSXPCConnection(machServiceName: helperMachServiceName, options: .privileged)
            active.remoteObjectInterface = NSXPCInterface(with: HelperXPC.self)
            active.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connectionLost() }
            }
            // The helper restarted, and restored system control as it started. Show that rather than the old state.
            active.interruptionHandler = { [weak self] in
                Task { @MainActor in await self?.refresh() }
            }
            active.resume()
            connection = active
        }
        return active.remoteObjectProxyWithErrorHandler(onError) as? any HelperXPC
    }

    private func connectionLost() {
        connection = nil
        if state == .running { state = .notResponding }
    }

    /// Works out the state without trusting anything the helper says about itself.
    func refresh() async {
        guard FileManager.default.fileExists(atPath: HelperPaths.launchDaemon) else {
            state = .notInstalled
            status = nil
            return
        }
        if let data = FileManager.default.contents(atPath: HelperPaths.pinFile),
           let pin = try? JSONDecoder().decode(PinnedClient.self, from: data),
           let own = Self.ownCodeHash() {
            guard own.lowercased() == pin.cdhash.lowercased() else {
                state = .needsRepin
                status = nil
                return
            }
            guard Bundle.main.bundlePath == HelperPaths.installedApp else {
                state = .notInstalledCopy
                status = nil
                return
            }
        }
        await send { proxy, reply in proxy.status(reply: reply) }
    }

    func applyFans(_ request: FanRequest) async {
        guard let data = try? JSONEncoder().encode(request) else { return }
        await send { proxy, reply in proxy.applyFans(data, reply: reply) }
        updateHeartbeat()
    }

    func applyCharge(_ request: ChargeRequest) async {
        guard let data = try? JSONEncoder().encode(request) else { return }
        await send { proxy, reply in proxy.applyCharge(data, reply: reply) }
    }

    func restoreDefaults() async {
        await send { proxy, reply in proxy.restoreDefaults(reply: reply) }
        updateHeartbeat()
    }

    private func send(_ call: @escaping (any HelperXPC, @escaping @Sendable (Data?) -> Void) -> Void) async {
        let data: Data? = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let once = ResumeOnce(continuation)
            guard let proxy = proxy(onError: { _ in once.resume(nil) }) else {
                once.resume(nil)
                return
            }
            call(proxy) { reply in once.resume(reply) }
            // An unresponsive helper must not hang the UI.
            Task {
                try? await Task.sleep(for: .seconds(3))
                once.resume(nil)
            }
        }
        guard let data, let reply = try? JSONDecoder().decode(HelperReply.self, from: data) else {
            state = .notResponding
            status = nil
            return
        }
        guard reply.status.protocolVersion == helperProtocolVersion else {
            state = .outdated
            status = nil
            return
        }
        state = .running
        status = reply.status
        lastError = reply.error ?? reply.status.lastError
    }

    /// Runs only while fans are under control. If it stops, the helper hands the fans back. Invariant 3.
    private func updateHeartbeat() {
        let active: Bool
        if let status {
            active = status.fanRequest?.policies.values.contains { $0 != .system } ?? false
        } else {
            // A missed reply is not proof that control ended. Stopping here would make the helper hand fans back
            // 20 s later, so the loop keeps trying for a while. Past the helper's own timeout there is nothing left
            // to keep alive.
            active = heartbeatTask != nil && state == .notResponding && missedBeats < Self.maxMissedBeats
        }
        guard active else {
            stopHeartbeat()
            return
        }
        guard heartbeatTask == nil else { return }
        // App Nap could delay a heartbeat past the helper's timeout.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Keeping fan control alive")
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.beat()
            }
        }
    }

    private func beat() async {
        guard state == .running || state == .notResponding else { return }
        proxy(onError: { _ in })?.heartbeat()
        await send { proxy, reply in proxy.status(reply: reply) }
        missedBeats = state == .running ? 0 : missedBeats + 1
        updateHeartbeat()
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        missedBeats = 0
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private static func ownCodeHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any], let unique = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}

/// XPC can call back zero, one or, with the timeout, two times. A continuation must resume exactly once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?

    init(_ continuation: CheckedContinuation<Data?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Data?) {
        let taken = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(returning: value)
    }
}
