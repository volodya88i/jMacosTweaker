import Foundation
import IOKit

public protocol FrequencyReading: Sendable {
    func sample() -> FrequencySnapshot?
}

/// Pure frequency math, testable without IOReport.
public enum FrequencyMath {
    /// `pmgr` tables have two formats. CPU tables store a period where MHz = 65536000 / value (M4 Pro: 14524 -> 4512,
    /// 25283 -> 2592). GPU tables store hertz (1578000000). Out-of-range entries become nil.
    public static func decodeTable(_ data: Data) -> [Double?] {
        stride(from: 0, to: data.count - data.count % 8, by: 8).map { offset in
            let raw = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + offset + $1]) << UInt32($1 * 8) }
            guard raw > 0 else { return nil }
            let mhz = raw >= 100_000_000 ? Double(raw) / 1_000_000 : 65_536_000 / Double(raw)
            return (50...8000).contains(mhz) ? mhz : nil
        }
    }

    /// Residency-weighted average over active states. Returns nil if no active residency exists, or the table does
    /// not match the state count, because then the mapping cannot be trusted.
    public static func average(residencies: [Int64], table: [Double?]) -> Double? {
        guard residencies.count == table.count else { return nil }
        var weighted = 0.0, total = 0.0
        for (residency, mhz) in zip(residencies, table) where residency > 0 {
            guard let mhz else { continue }
            weighted += Double(residency) * mhz
            total += Double(residency)
        }
        return total > 0 ? weighted / total : nil
    }
}

/// Average CPU and GPU frequency from IOReport. The subscription is created on first use and only exists while a view
/// asks for frequency. Table mapping verified on M4 Pro only; on other chips a state count mismatch yields nil.
public final class FrequencyReader: FrequencyReading, @unchecked Sendable {
    private typealias CopyGroup = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscription = @convention(c) (
        UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?
    ) -> OpaquePointer?
    private typealias Samples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Text = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias Residency = @convention(c) (CFDictionary, Int32) -> Int64

    private let copyGroup: CopyGroup
    private let createSubscription: CreateSubscription
    private let samples: Samples
    private let delta: Delta
    private let channelName: Text
    private let stateCount: StateCount
    private let stateName: StateName
    private let residency: Residency

    private let lock = NSLock()
    private var subscription: OpaquePointer?
    private var subscribed: CFMutableDictionary?
    private var previous: CFDictionary?
    private var tables: (efficiency: [Double?], performance: [Double?], gpu: [Double?])?

    public init?() {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: type) }
        }
        guard let copyGroup = symbol("IOReportCopyChannelsInGroup", as: CopyGroup.self),
              let createSubscription = symbol("IOReportCreateSubscription", as: CreateSubscription.self),
              let samples = symbol("IOReportCreateSamples", as: Samples.self),
              let delta = symbol("IOReportCreateSamplesDelta", as: Delta.self),
              let channelName = symbol("IOReportChannelGetChannelName", as: Text.self),
              let stateCount = symbol("IOReportStateGetCount", as: StateCount.self),
              let stateName = symbol("IOReportStateGetNameForIndex", as: StateName.self),
              let residency = symbol("IOReportStateGetResidency", as: Residency.self) else { return nil }
        self.copyGroup = copyGroup
        self.createSubscription = createSubscription
        self.samples = samples
        self.delta = delta
        self.channelName = channelName
        self.stateCount = stateCount
        self.stateName = stateName
        self.residency = residency
    }

    public func sample() -> FrequencySnapshot? {
        lock.withLock {
            guard ensureSubscribed(), let subscription, let subscribed,
                  let current = samples(subscription, subscribed, nil)?.takeRetainedValue() else { return nil }
            defer { previous = current }
            guard let previous,
                  let difference = delta(previous, current, nil)?.takeRetainedValue() as? [String: Any],
                  let rows = difference["IOReportChannels"] as? [CFDictionary] else { return nil }
            return summarize(rows)
        }
    }

    private func ensureSubscribed() -> Bool {
        if subscription != nil { return true }
        guard let cpu = copyGroup("CPU Stats" as CFString, "CPU Core Performance States" as CFString, 0, 0, 0)?.takeRetainedValue(),
              let gpu = copyGroup("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0, 0)?.takeRetainedValue(),
              let cpuChannels = (cpu as NSDictionary)["IOReportChannels"] as? [Any],
              let gpuChannels = (gpu as NSDictionary)["IOReportChannels"] as? [Any],
              let merged = (cpu as NSDictionary).mutableCopy() as? NSMutableDictionary else { return false }
        merged["IOReportChannels"] = cpuChannels + gpuChannels
        var output: Unmanaged<CFMutableDictionary>?
        guard let created = createSubscription(nil, merged as CFMutableDictionary, &output, 0, nil),
              let channels = output?.takeRetainedValue() else { return false }
        subscription = created
        subscribed = channels
        if tables == nil { tables = Self.readTables() }
        return true
    }

    private func summarize(_ rows: [CFDictionary]) -> FrequencySnapshot {
        var efficiency: [Int64] = [], performance: [Int64] = [], gpu: [Int64] = []
        for row in rows {
            guard let name = channelName(row)?.takeUnretainedValue() as String? else { continue }
            let count = stateCount(row)
            if name == "GPUPH" {
                gpu = accumulate(gpu, row: row, count: count, skipIdle: false)
            } else if name.hasPrefix("ECPU") {
                efficiency = accumulate(efficiency, row: row, count: count, skipIdle: true)
            } else if name.hasPrefix("PCPU") {
                performance = accumulate(performance, row: row, count: count, skipIdle: true)
            }
        }
        return FrequencySnapshot(
            performanceMHz: tables.flatMap { FrequencyMath.average(residencies: performance, table: $0.performance) },
            efficiencyMHz: tables.flatMap { FrequencyMath.average(residencies: efficiency, table: $0.efficiency) },
            gpuMHz: tables.flatMap { FrequencyMath.average(residencies: gpu, table: $0.gpu) }
        )
    }

    /// CPU channels list DOWN and IDLE before the active states, so they are skipped to line up with the table.
    private func accumulate(_ sums: [Int64], row: CFDictionary, count: Int32, skipIdle: Bool) -> [Int64] {
        var result = sums
        var slot = 0
        for index in 0..<count {
            if skipIdle, let name = stateName(row, index)?.takeUnretainedValue() as String?, name == "DOWN" || name == "IDLE" {
                continue
            }
            let value = residency(row, index)
            if slot < result.count { result[slot] += value } else { result.append(value) }
            slot += 1
        }
        return result
    }

    /// Table numbers verified on M4 Pro by state count and published clocks: 1 = E, 5 = P, 9 = GPU.
    private static func readTables() -> (efficiency: [Double?], performance: [Double?], gpu: [Double?])? {
        let matching = IOServiceNameMatching("pmgr")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func table(_ number: Int) -> [Double?] {
            let name = "voltage-states\(number)" as CFString
            guard let data = IORegistryEntryCreateCFProperty(service, name, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data else { return [] }
            return FrequencyMath.decodeTable(data)
        }
        return (table(1), table(5), table(9))
    }
}
