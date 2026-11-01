import Foundation

public struct CPUCoreLoad: Hashable, Sendable {
    public let index: Int
    public let kind: CPUCoreKind
    public let usage: Double

    public init(index: Int, kind: CPUCoreKind, usage: Double) {
        self.index = index
        self.kind = kind
        self.usage = usage
    }
}

public enum CPUCoreKind: String, Hashable, Sendable {
    case performance
    case efficiency
    case unknown
}

public struct CPUSnapshot: Hashable, Sendable {
    /// Fractions from 0 to 1. `user + system + idle` is about 1.
    public let user: Double
    public let system: Double
    public let idle: Double
    public let cores: [CPUCoreLoad]

    public init(user: Double, system: Double, idle: Double, cores: [CPUCoreLoad]) {
        self.user = user
        self.system = system
        self.idle = idle
        self.cores = cores
    }

    public var usage: Double { min(max(user + system, 0), 1) }

    public func clusterUsage(_ kind: CPUCoreKind) -> Double? {
        let members = cores.filter { $0.kind == kind }
        guard !members.isEmpty else { return nil }
        return members.reduce(0) { $0 + $1.usage } / Double(members.count)
    }
}

public enum MemoryPressure: String, Hashable, Sendable {
    case normal
    case warning
    case critical
    case unknown
}

public struct MemorySnapshot: Hashable, Sendable {
    public let total: UInt64
    public let app: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let cached: UInt64
    public let free: UInt64
    public let swapUsed: UInt64
    public let pressure: MemoryPressure

    public init(
        total: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, cached: UInt64, free: UInt64, swapUsed: UInt64,
        pressure: MemoryPressure
    ) {
        self.total = total
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.cached = cached
        self.free = free
        self.swapUsed = swapUsed
        self.pressure = pressure
    }

    /// Same definition as Activity Monitor's "Memory Used": app + wired + compressed.
    public var used: UInt64 { app + wired + compressed }

    public var usage: Double {
        total == 0 ? 0 : min(Double(used) / Double(total), 1)
    }
}

public struct GPUSnapshot: Hashable, Sendable {
    /// Fractions from 0 to 1. Renderer and tiler can be missing.
    public let device: Double
    public let renderer: Double?
    public let tiler: Double?

    public init(device: Double, renderer: Double?, tiler: Double?) {
        self.device = device
        self.renderer = renderer
        self.tiler = tiler
    }
}

public struct FrequencySnapshot: Hashable, Sendable {
    /// Residency-weighted average frequency in MHz, nil when it could not be derived.
    public let performanceMHz: Double?
    public let efficiencyMHz: Double?
    public let gpuMHz: Double?

    public init(performanceMHz: Double?, efficiencyMHz: Double?, gpuMHz: Double?) {
        self.performanceMHz = performanceMHz
        self.efficiencyMHz = efficiencyMHz
        self.gpuMHz = gpuMHz
    }
}

public protocol CPUReading: Sendable {
    func sample() -> CPUSnapshot?
}

public protocol MemoryReading: Sendable {
    func sample() -> MemorySnapshot?
}

public protocol GPUReading: Sendable {
    func sample() -> GPUSnapshot?
}
