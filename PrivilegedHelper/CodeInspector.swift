import Foundation
import HelperCore
import Security

/// Reads a connecting process's identity from its audit token, which cannot be spoofed by PID reuse.
enum CodeInspector {
    static func identity(auditToken: audit_token_t) -> ClientIdentity? {
        let tokenData = withUnsafeBytes(of: auditToken) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let code = guest else { return nil }
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let info = information as? [String: Any],
              let unique = info[kSecCodeInfoUnique as String] as? Data else { return nil }

        var urlRef: CFURL?
        guard SecCodeCopyPath(staticCode, [], &urlRef) == errSecSuccess, let url = urlRef as URL? else { return nil }
        let executable = (info[kSecCodeInfoMainExecutable as String] as? URL)?.path ?? url.path

        let codeFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let ownership = pathOwnership(executable: executable)
        return ClientIdentity(
            cdhash: unique.map { String(format: "%02x", $0) }.joined(),
            path: executable,
            pathOwnedByRoot: ownership.root,
            pathWritableByOthers: ownership.writable,
            hasHardenedRuntime: codeFlags & SecCodeSignatureFlags.runtime.rawValue != 0,
            allowsDebugging: entitlements?["com.apple.security.get-task-allow"] as? Bool ?? false
        )
    }

    /// Checks the executable and each folder up to and including the `.app` bundle.
    private static func pathOwnership(executable: String) -> (root: Bool, writable: Bool) {
        var root = true
        var writable = false
        var current = executable
        while true {
            var info = stat()
            guard lstat(current, &info) == 0 else { return (false, true) }
            if info.st_uid != 0 { root = false }
            if info.st_mode & (S_IWGRP | S_IWOTH) != 0 { writable = true }
            if current.hasSuffix(".app") || current == "/" { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return (root, writable)
    }
}
