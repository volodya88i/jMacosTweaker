import Foundation
import Shared

public struct ClientIdentity: Equatable, Sendable {
    public var cdhash: String
    public var path: String
    public var pathOwnedByRoot: Bool
    public var pathWritableByOthers: Bool
    public var hasHardenedRuntime: Bool
    public var allowsDebugging: Bool

    public init(cdhash: String, path: String, pathOwnedByRoot: Bool, pathWritableByOthers: Bool, hasHardenedRuntime: Bool, allowsDebugging: Bool) {
        self.cdhash = cdhash
        self.path = path
        self.pathOwnedByRoot = pathOwnedByRoot
        self.pathWritableByOthers = pathWritableByOthers
        self.hasHardenedRuntime = hasHardenedRuntime
        self.allowsDebugging = allowsDebugging
    }
}

public enum ClientRejection: Equatable, Sendable {
    case noPin, unreadableIdentity, hashMismatch, pathMismatch, pathNotRootOwned, pathWritable, noHardenedRuntime, debuggable
}

/// Decides whether a connecting process is the pinned app. Invariant 2. The weakness of this approach without a
/// Developer ID is documented in SAFETY.md.
public enum ClientVerifier {
    public static func check(identity: ClientIdentity?, pin: PinnedClient?) -> ClientRejection? {
        guard let pin else { return .noPin }
        guard let identity else { return .unreadableIdentity }
        guard !pin.cdhash.isEmpty, identity.cdhash.lowercased() == pin.cdhash.lowercased() else { return .hashMismatch }
        guard identity.path == pin.path else { return .pathMismatch }
        guard identity.pathOwnedByRoot else { return .pathNotRootOwned }
        guard !identity.pathWritableByOthers else { return .pathWritable }
        guard identity.hasHardenedRuntime else { return .noHardenedRuntime }
        guard !identity.allowsDebugging else { return .debuggable }
        return nil
    }
}
