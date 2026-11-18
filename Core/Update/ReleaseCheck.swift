import Foundation

/// A release number such as 0.2.2. Tags from GitHub are untrusted text, so anything but one to three plain numbers is
/// refused.
public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") { trimmed.removeFirst() }
        guard (1...20).contains(trimmed.count) else { return nil }
        let pieces = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard (1...4).contains(piece.count), piece.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(piece) else { return nil }
            parts.append(value)
        }
        while parts.count < 3 { parts.append(0) }
        self.parts = parts
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.parts.lexicographicallyPrecedes(rhs.parts)
    }
}

public struct LatestRelease: Hashable, Sendable {
    public let version: ReleaseVersion
    /// Built from the version, never taken from the response, so only the project's own release page can open.
    public let pageURL: URL

    public init(version: ReleaseVersion) {
        self.version = version
        pageURL = ReleaseCheck.pageURL(for: version)
    }
}

/// Reads GitHub's latest release for the public repository. Only the version is used; nothing about this Mac is sent.
public enum ReleaseCheck {
    public static let repository = "volodya88i/jMacosTweaker"
    public static let apiURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    /// A real reply is a few kilobytes.
    public static let maximumResponseSize = 512 * 1024

    private struct Reply: Decodable {
        var tag_name: String
        var draft: Bool?
        var prerelease: Bool?
    }

    public static func parse(_ data: Data) -> LatestRelease? {
        guard data.count <= maximumResponseSize, let reply = try? JSONDecoder().decode(Reply.self, from: data),
              reply.draft != true, reply.prerelease != true, let version = ReleaseVersion(reply.tag_name) else { return nil }
        return LatestRelease(version: version)
    }

    public static func pageURL(for version: ReleaseVersion) -> URL {
        releasesPage.appendingPathComponent("tag").appendingPathComponent("v\(version)")
    }
}
