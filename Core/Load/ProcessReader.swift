import Darwin
import Foundation

public struct ProcessUsage: Hashable, Sendable, Identifiable {
    public let pid: Int32
    public let name: String
    /// 1 means one full core.
    public let cpu: Double
    public let memory: UInt64

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, cpu: Double, memory: UInt64) {
        self.pid = pid
        self.name = name
        self.cpu = cpu
        self.memory = memory
    }
}

public struct ProcessSnapshot: Hashable, Sendable {
    public let byCPU: [ProcessUsage]
    public let byMemory: [ProcessUsage]

    public init(byCPU: [ProcessUsage], byMemory: [ProcessUsage]) {
        self.byCPU = byCPU
        self.byMemory = byMemory
    }

    public static func top(_ all: [ProcessUsage], count: Int) -> ProcessSnapshot {
        ProcessSnapshot(
            byCPU: Array(all.sorted { $0.cpu > $1.cpu }.prefix(count)),
            byMemory: Array(all.sorted { $0.memory > $1.memory }.prefix(count))
        )
    }
}

public protocol ProcessReading: Sendable {
    /// Nil on the first call, because CPU use needs two samples.
    func sample() -> ProcessSnapshot?
}

public enum ProcessMath {
    /// CPU time is cumulative. Smaller means the PID was reused by a new process, which has no usable difference yet.
    public static func cpu(newTime: UInt64, oldTime: UInt64, elapsedSeconds: TimeInterval, nanosecondsPerTick: Double) -> Double {
        guard elapsedSeconds > 0, newTime >= oldTime else { return 0 }
        return Double(newTime - oldTime) * nanosecondsPerTick / 1e9 / elapsedSeconds
    }
}

/// Runs only while a view shows processes. Without root, only the current user's processes can be read, so system
/// processes are missing from this list, and the UI says so.
public final class ProcessReader: ProcessReading, @unchecked Sendable {
    private let lock = NSLock()
    private var previous: [Int32: UInt64] = [:]
    private var lastTime: TimeInterval?
    private let nanosecondsPerTick: Double

    public init() {
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        nanosecondsPerTick = timebase.denom == 0 ? 1 : Double(timebase.numer) / Double(timebase.denom)
    }

    public func sample() -> ProcessSnapshot? {
        var capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        capacity += 32
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, capacity * Int32(MemoryLayout<pid_t>.stride)) }
        guard count > 0 else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        var times: [Int32: UInt64] = [:]
        var memory: [Int32: UInt64] = [:]
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard status == 0 else { continue }
            times[pid] = usage.ri_user_time + usage.ri_system_time
            memory[pid] = usage.ri_phys_footprint
        }
        return lock.withLock {
            defer {
                previous = times
                lastTime = now
            }
            guard let lastTime, now > lastTime else { return nil }
            let elapsed = now - lastTime
            var all: [ProcessUsage] = []
            all.reserveCapacity(times.count)
            for (pid, time) in times {
                let cpu = previous[pid].map { ProcessMath.cpu(newTime: time, oldTime: $0, elapsedSeconds: elapsed, nanosecondsPerTick: nanosecondsPerTick) } ?? 0
                all.append(ProcessUsage(pid: pid, name: Self.name(of: pid), cpu: cpu, memory: memory[pid] ?? 0))
            }
            return ProcessSnapshot.top(all, count: 5)
        }
    }

    private static func name(of pid: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : "PID \(pid)"
    }
}
