import Core
import Foundation

/// Overrides every preset and curve. Cannot be turned off, and has no setter for its limits. Invariant 4.
public struct ThermalSupervisor: Sendable {
    public struct Limits: Sendable {
        public var cpuGPU = 95.0
        public var ssd = 75.0
        public var battery = 50.0
        public var recovery = 10.0

        public init() {}
    }

    public let limits: Limits
    public private(set) var reason: String?

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public var isOverriding: Bool { reason != nil }

    @discardableResult
    public mutating func update(summary: TemperatureSummary) -> Bool {
        let checks: [(String, Double?, Double)] = [
            ("CPU", summary.cpuHottest, limits.cpuGPU),
            ("GPU", summary.gpu, limits.cpuGPU),
            ("SSD", summary.ssd, limits.ssd),
            ("Battery", summary.battery, limits.battery)
        ]
        if let hot = checks.first(where: { ($0.1 ?? -.infinity) >= $0.2 }) {
            reason = "\(hot.0) reached \(Int(hot.1 ?? 0)) °C"
            return true
        }
        // Stays engaged until everything is well below its limit.
        if reason != nil, checks.contains(where: { ($0.1 ?? -.infinity) > $0.2 - limits.recovery }) {
            return true
        }
        reason = nil
        return false
    }
}
