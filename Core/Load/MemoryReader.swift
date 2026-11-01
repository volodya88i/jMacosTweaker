import Darwin
import Foundation

/// Memory figures from `host_statistics64` and sysctl. Needs no privileges.
public final class MemoryReader: MemoryReading, @unchecked Sendable {
    private let total: UInt64

    public init() {
        total = ProcessInfo.processInfo.physicalMemory
    }

    public func sample() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        return MemorySnapshot(
            total: total,
            app: (internalPages > purgeable ? internalPages - purgeable : 0) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            cached: (UInt64(stats.external_page_count) + purgeable) * page,
            free: UInt64(stats.free_count) * page,
            swapUsed: Self.swapUsed(),
            pressure: Self.pressure()
        )
    }

    private static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    private static func pressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.stride
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .unknown }
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }
}
