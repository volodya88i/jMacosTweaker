import Foundation

public struct FanSnapshot: Hashable, Sendable {
    public let index: Int
    public let actualRPM: Double
    public let minimumRPM: Double
    public let maximumRPM: Double
    public let targetRPM: Double?
    /// Raw mode value. Meanings are UNVERIFIED on this hardware, so it is shown only in diagnostics.
    public let mode: Int?

    public init(index: Int, actualRPM: Double, minimumRPM: Double, maximumRPM: Double, targetRPM: Double?, mode: Int?) {
        self.index = index
        self.actualRPM = actualRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.targetRPM = targetRPM
        self.mode = mode
    }
}

public protocol FanReading: Sendable {
    /// Number of fans found at start. Zero hides all fan UI.
    var fanCount: Int { get }
    func sample() -> [FanSnapshot]
}

/// SMC key names per fan index. The pattern was verified by enumeration on Mac16,8.
public enum FanKeys {
    public static let count: SMCKey = "FNum"

    private static func key(_ index: Int, _ suffix: String) -> SMCKey {
        SMCKey(string: "F\(index)\(suffix)") ?? "F0Ac"
    }

    public static func actual(_ index: Int) -> SMCKey { key(index, "Ac") }
    public static func minimum(_ index: Int) -> SMCKey { key(index, "Mn") }
    public static func maximum(_ index: Int) -> SMCKey { key(index, "Mx") }
    public static func target(_ index: Int) -> SMCKey { key(index, "Tg") }
    public static func mode(_ index: Int) -> SMCKey { key(index, "Md") }
}

public final class FanReader: FanReading, @unchecked Sendable {
    private let smc: any SMCReading
    public let fanCount: Int
    /// Limits are hardware constants, cached after the first read.
    private let limits: [(minimum: Double, maximum: Double)]

    public init(smc: any SMCReading) {
        self.smc = smc
        var found: [(minimum: Double, maximum: Double)] = []
        let reported = Int(smc.number(FanKeys.count) ?? 0)
        for index in 0..<min(max(reported, 0), 10) {
            guard let minimum = smc.number(FanKeys.minimum(index)),
                  let maximum = smc.number(FanKeys.maximum(index)),
                  minimum >= 0, maximum > minimum, maximum < 30000 else { break }
            found.append((minimum, maximum))
        }
        limits = found
        fanCount = found.count
    }

    public func sample() -> [FanSnapshot] {
        limits.enumerated().compactMap { index, limit in
            guard let actual = smc.number(FanKeys.actual(index)), actual >= 0, actual < 30000 else { return nil }
            return FanSnapshot(
                index: index,
                actualRPM: actual,
                minimumRPM: limit.minimum,
                maximumRPM: limit.maximum,
                targetRPM: smc.number(FanKeys.target(index)),
                mode: smc.number(FanKeys.mode(index)).map { Int($0) }
            )
        }
    }
}
