import Core
import Foundation
import Shared

/// Overrides every preset and curve. Invariant 4.
///
/// The owner can move the CPU and GPU limits within `OverheatProtection`'s ranges, or turn it off (owner's request,
/// 2026-11-26). Its boost stops at the top of the owner's curve, so a last-resort check remains, on or off, that no
/// setting removes: CPU or GPU averaging 110 °C, or the battery 55 °C, for 10 s hands fans back to macOS, which is never
/// less safe than the default.
///
/// Judges averages over a window, not single samples: on an M4 Pro the hottest P-core passes 95 to 100 °C for a second
/// or two on any burst of work, and an instant trigger sent fans to maximum many times an hour (owner report,
/// 2026-11-18). Only a truly critical sample acts at once. Once engaged, it raises fans in steps above whatever the
/// request wants, rather than jumping straight to maximum.
public struct ThermalSupervisor: Sendable {
    public struct Limits: Sendable {
        /// CPU or GPU averaged over `window` at or above this engages.
        public var sustainedCPUGPU = 100.0
        /// A single CPU or GPU sample at or above this engages at once, at full speed. Apple Silicon throttles near 110 °C.
        public var criticalCPUGPU = 108.0
        /// Released once the CPU and GPU averages are below this.
        public var releaseCPUGPU = 92.0
        public var ssd = 75.0
        public var battery = 50.0
        /// SSD and battery release this far below their limit.
        public var recovery = 10.0
        public var window: TimeInterval = 10
        /// Each step adds `stepPercent` of the fan's range, this often, until the heat is gone or fans are at maximum.
        public var stepInterval: TimeInterval = 5
        public var stepPercent = 25.0
        public var enabled = true
        /// On or off: averages at or above these hand fans back to macOS.
        public var backstopCPUGPU = 110.0
        public var backstopBattery = 55.0

        public init() {}

        /// The owner's settings, clamped. SSD and battery limits are not configurable.
        public init(_ protection: OverheatProtection) {
            let value = protection.clamped
            enabled = value.enabled
            sustainedCPUGPU = value.sustainedCelsius
            criticalCPUGPU = value.criticalCelsius
            releaseCPUGPU = value.sustainedCelsius - 8
        }
    }

    private struct Sample: Sendable {
        var time: TimeInterval
        var cpu: Double?
        var gpu: Double?
        var ssd: Double?
        var battery: Double?
    }

    public private(set) var limits: Limits
    public private(set) var reason: String?
    /// Why fans must go back to macOS now. Nil otherwise.
    public private(set) var backstop: String?
    /// Percent of each fan's range added on top of what the request wants. 0 while not engaged, 100 when critical.
    public private(set) var boostPercent = 0.0
    private var samples: [Sample] = []
    private var engagedAt: TimeInterval?
    private var critical = false

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public var isOverriding: Bool { reason != nil }

    /// New limits keep the temperature history, so a change does not restart the averaging window.
    public mutating func configure(_ protection: OverheatProtection) {
        let next = Limits(protection)
        guard next.enabled != limits.enabled || next.sustainedCPUGPU != limits.sustainedCPUGPU
            || next.criticalCPUGPU != limits.criticalCPUGPU else { return }
        limits = next
        release()
        backstop = nil
    }

    @discardableResult
    public mutating func update(summary: TemperatureSummary, now: TimeInterval) -> Bool {
        samples.append(Sample(time: now, cpu: summary.cpuHottest, gpu: summary.gpu, ssd: summary.ssd, battery: summary.battery))
        samples.removeAll { $0.time <= now - limits.window || $0.time > now }
        // An average needs most of a window behind it. Until then only the critical check can engage.
        let covered = (samples.first.map { now - $0.time } ?? 0) >= limits.window * 0.8

        let cpu = average(\.cpu)
        let gpu = average(\.gpu)
        let ssd = average(\.ssd)
        let battery = average(\.battery)

        backstop = nil
        if covered, let hot = [
            ("CPU", cpu, limits.backstopCPUGPU), ("GPU", gpu, limits.backstopCPUGPU), ("Battery", battery, limits.backstopBattery)
        ].first(where: { ($0.1 ?? -.infinity) >= $0.2 }) {
            backstop = "\(hot.0) averaged \(Int(hot.1 ?? 0)) °C for \(Int(limits.window)) s"
        }
        guard limits.enabled else { return false }

        let instant = [("CPU", summary.cpuHottest), ("GPU", summary.gpu)].first { ($0.1 ?? -.infinity) >= limits.criticalCPUGPU }
        if let instant {
            critical = true
            engage(now: now, reason: "\(instant.0) reached \(Int(instant.1 ?? 0)) °C")
        } else if covered, let hot = [
            ("CPU", cpu, limits.sustainedCPUGPU), ("GPU", gpu, limits.sustainedCPUGPU),
            ("SSD", ssd, limits.ssd), ("Battery", battery, limits.battery)
        ].first(where: { ($0.1 ?? -.infinity) >= $0.2 }) {
            engage(now: now, reason: "\(hot.0) averaged \(Int(hot.1 ?? 0)) °C for \(Int(limits.window)) s")
        } else if reason != nil {
            // Stays engaged until everything is well below its limit, judged on the same averages.
            let stillWarm = (cpu ?? -.infinity) >= limits.releaseCPUGPU || (gpu ?? -.infinity) >= limits.releaseCPUGPU
                || (ssd ?? -.infinity) > limits.ssd - limits.recovery || (battery ?? -.infinity) > limits.battery - limits.recovery
            if !stillWarm { release() }
        }

        if let engagedAt {
            let steps = 1 + ((now - engagedAt) / limits.stepInterval).rounded(.down)
            boostPercent = critical ? 100 : min(100, steps * limits.stepPercent)
        }
        return reason != nil
    }

    /// The request's percent with the boost added. Unchanged while not engaged.
    public func boosted(_ percent: Double) -> Double {
        guard isOverriding else { return percent }
        return min(100, percent + boostPercent)
    }

    public mutating func reset() {
        self = ThermalSupervisor(limits: limits)
    }

    private mutating func engage(now: TimeInterval, reason: String) {
        if engagedAt == nil { engagedAt = now }
        self.reason = reason
    }

    private mutating func release() {
        reason = nil
        engagedAt = nil
        critical = false
        boostPercent = 0
    }

    private func average(_ path: KeyPath<Sample, Double?>) -> Double? {
        let values = samples.compactMap { $0[keyPath: path] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
