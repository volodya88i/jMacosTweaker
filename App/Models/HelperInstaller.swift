import AppKit
import Foundation
import Security

/// Runs the bundled install and uninstall scripts with administrator rights, from a button instead of Terminal.
///
/// macOS asks for the password in its own dialog, through `do shell script … with administrator privileges`. The app
/// never sees or stores the password. The scripts are the same ones the Terminal commands run, and they verify a
/// root-owned copy of the app before trusting it; the app also checks its own signature first, so a bundle whose
/// scripts were changed is refused before anything runs as root.
@MainActor
@Observable
final class HelperInstaller {
    enum Action: Equatable {
        case install(allowUnverified: Bool)
        case uninstall
    }

    private(set) var running: Action?
    private(set) var failure: String?
    private(set) var lastSuccess: Action?

    static let installedApp = "/Applications/jMacosTweaker.app"

    /// Returns true when the action finished. Cancelling the password dialog is not a failure and shows nothing.
    @discardableResult
    func run(_ action: Action) async -> Bool {
        guard running == nil else { return false }
        failure = nil
        lastSuccess = nil
        guard Self.ownSignatureIsValid() else {
            failure = String(localized: "This copy of jMacosTweaker has been changed since it was signed, so its installer will not run. Download the app again.")
            return false
        }
        let resources = Bundle.main.resourcePath ?? ""
        var command: [String]
        let prompt: String
        switch action {
        case let .install(allowUnverified):
            command = ["/bin/bash", resources + "/install_helper.sh", Bundle.main.bundlePath]
            if allowUnverified { command.append("--allow-unverified-control") }
            prompt = String(localized: "jMacosTweaker wants to install its helper, which controls fans and charging.")
        case .uninstall:
            command = ["/bin/bash", resources + "/uninstall_helper.sh"]
            prompt = String(localized: "jMacosTweaker wants to remove its helper. Fans and charging return to macOS.")
        }
        running = action
        defer { running = nil }
        let shell = command.map(Self.shellQuoted).joined(separator: " ")
        let script = "do shell script \(Self.appleScriptString(shell)) with prompt \(Self.appleScriptString(prompt)) with administrator privileges"
        let outcome = await Task.detached { Self.osascript(script) }.value
        switch outcome {
        case .finished:
            lastSuccess = action
            return true
        case .cancelled:
            return false
        case let .failed(message):
            failure = message
            return false
        }
    }

    /// After installing from somewhere else, such as the disk image, the pinned copy is the one in Applications.
    var shouldRelaunchInstalledCopy: Bool {
        Bundle.main.bundlePath != Self.installedApp && FileManager.default.fileExists(atPath: Self.installedApp)
    }

    func relaunchInstalledCopy() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits until this copy has quit, so two copies never hold the menu bar at once.
        process.arguments = ["-c", "sleep 1; /usr/bin/open \(Self.shellQuoted(Self.installedApp))"]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: Running

    private enum Outcome: Sendable {
        case finished
        case cancelled
        case failed(String)
    }

    private nonisolated static func osascript(_ script: String) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            return .failed(String(localized: "The installer could not be started."))
        }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return .finished }
        let text = String(decoding: data, as: UTF8.self)
        // -128 is "User canceled" from the password dialog.
        if text.contains("(-128)") { return .cancelled }
        return .failed(message(from: text))
    }

    /// The scripts report problems as "error: …". osascript wraps that in its own prefix and an error number.
    private nonisolated static func message(from text: String) -> String {
        if let range = text.range(of: "error: ", options: .backwards) {
            var message = String(text[range.upperBound...])
            if let end = message.range(of: " (", options: .backwards) { message = String(message[..<end.lowerBound]) }
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed.prefix(1).uppercased() + trimmed.dropFirst() }
        }
        return String(localized: "The installer stopped with an error. The Terminal command below shows the details.")
    }

    // MARK: Quoting and signature

    nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The whole bundle, scripts included, must still match its signature.
    private static func ownSignatureIsValid() -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: SecCSFlags.RawValue(kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode))
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }
}
