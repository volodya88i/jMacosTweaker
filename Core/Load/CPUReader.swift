import Darwin
import Foundation
import IOKit

/// Pure delta math, separate from the Mach call so it can be tested.
public struct CPUTicks: Hashable, Sendable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// Counters are 32-bit in the kernel and wrap, so a smaller value means a wrap and is handled by `&-`
    /// on the low 32 bits.
    static func delta(_ new: UInt64, _ old: UInt64) -> Double {
        Double(UInt32(truncatingIfNeeded: new) &- UInt32(truncatingIfNeeded: old))
    }
}

public enum CPULoadMath {
    public static func snapshot(old: [CPUTicks], new: [CPUTicks], kinds: [CPUCoreKind]) -> CPUSnapshot? {
        guard old.count == new.count, !new.isEmpty else { return nil }
        var user = 0.0, system = 0.0, idle = 0.0
        var cores: [CPUCoreLoad] = []
        cores.reserveCapacity(new.count)
        for index in new.indices {
            let coreUser = CPUTicks.delta(new[index].user, old[index].user) + CPUTicks.delta(new[index].nice, old[index].nice)
            let coreSystem = CPUTicks.delta(new[index].system, old[index].system)
            let coreIdle = CPUTicks.delta(new[index].idle, old[index].idle)
            user += coreUser
            system += coreSystem
            idle += coreIdle
            let total = coreUser + coreSystem + coreIdle
            let kind = index < kinds.count ? kinds[index] : .unknown
            cores.append(CPUCoreLoad(index: index, kind: kind, usage: total > 0 ? (coreUser + coreSystem) / total : 0))
        }
        let total = user + system + idle
        guard total > 0 else { return nil }
        return CPUSnapshot(user: user / total, system: system / total, idle: idle / total, cores: cores)
    }
}

/// CPU load from `host_processor_info`. Needs no privileges.
public final class CPUReader: CPUReading, @unchecked Sendable {
    private let lock = NSLock()
    private var previous: [CPUTicks] = []
    private let kinds: [CPUCoreKind]

    public init() {
        kinds = CPUTopology.coreKinds()
    }

    public func sample() -> CPUSnapshot? {
        guard let current = Self.readTicks() else { return nil }
        return lock.withLock {
            defer { previous = current }
            guard previous.count == current.count else { return nil }
            return CPULoadMath.snapshot(old: previous, new: current, kinds: kinds)
        }
    }

    private static func readTicks() -> [CPUTicks]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let status = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
        guard status == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { core in
            let base = core * states
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            return CPUTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM), idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }
}

/// Maps each logical CPU to its cluster kind from the device tree. Empty on Intel, where every core is `.unknown`.
public enum CPUTopology {
    public static func coreKinds() -> [CPUCoreKind] {
        var iterator: io_iterator_t = 0
        let plane = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard plane != 0 else { return [] }
        defer { IOObjectRelease(plane) }
        guard IORegistryEntryGetChildIterator(plane, "IODeviceTree", &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var byIndex: [Int: CPUCoreKind] = [:]
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let id = integerProperty(entry, "logical-cpu-id"),
                  let type = property(entry, "cluster-type")?.first else { continue }
            byIndex[id] = type == UInt8(ascii: "P") ? .performance : type == UInt8(ascii: "E") ? .efficiency : .unknown
        }
        guard let maxIndex = byIndex.keys.max() else { return [] }
        return (0...maxIndex).map { byIndex[$0] ?? .unknown }
    }

    private static func property(_ entry: io_registry_entry_t, _ name: String) -> Data? {
        IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
    }

    /// The device tree stores this as a number on current macOS and as little-endian bytes in older material.
    private static func integerProperty(_ entry: io_registry_entry_t, _ name: String) -> Int? {
        let value = IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        if let number = value as? NSNumber { return number.intValue }
        guard let data = value as? Data, !data.isEmpty, data.count <= 8 else { return nil }
        return data.reversed().reduce(0) { ($0 << 8) | Int($1) }
    }
}
