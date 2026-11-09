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
    case noPin, malformedPin, unreadableIdentity, hashMismatch, pathMismatch, pathNotRootOwned, pathWritable, noHardenedRuntime, debuggable
}

/// Decides whether a connecting process is the pinned app. Invariant 2. The weakness of this approach without a
/// Developer ID is documented in SAFETY.md.
public enum ClientVerifier {
    public static func check(identity: ClientIdentity?, pin: PinnedClient?) -> ClientRejection? {
        guard let pin else { return .noPin }
        // The pin also becomes part of a code signing requirement, so anything but a SHA-1 or SHA-256 sized hex string
        // is refused outright.
        guard isWellFormedHash(pin.cdhash), pin.path.hasPrefix("/"), !pin.path.contains("/../") else { return .malformedPin }
        guard let identity else { return .unreadableIdentity }
        guard identity.cdhash.lowercased() == pin.cdhash.lowercased() else { return .hashMismatch }
        guard identity.path == pin.path else { return .pathMismatch }
        guard identity.pathOwnedByRoot else { return .pathNotRootOwned }
        guard !identity.pathWritableByOthers else { return .pathWritable }
        guard identity.hasHardenedRuntime else { return .noHardenedRuntime }
        guard !identity.allowsDebugging else { return .debuggable }
        return nil
    }

    public static func isWellFormedHash(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
        }
    }
}
