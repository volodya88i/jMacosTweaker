import Darwin
import Foundation
import IOKit

/// Bytes per second in both directions: download and upload, or read and write.
public struct ThroughputSnapshot: Hashable, Sendable {
    public let incoming: Double
    public let outgoing: Double

    public init(incoming: Double, outgoing: Double) {
        self.incoming = incoming
        self.outgoing = outgoing
    }

    public var total: Double { incoming + outgoing }
}

public protocol ThroughputReading: Sendable {
    /// Nil on the first call, because a rate needs two samples.
    func sample() -> ThroughputSnapshot?
}

public enum ThroughputMath {
    /// Counters only rise, so a smaller value means a reset, or a device or interface that went away. That is not traffic.
    public static func rate(new: UInt64, old: UInt64, seconds: TimeInterval) -> Double {
        guard seconds > 0, new >= old else { return 0 }
        return Double(new - old) / seconds
    }

    /// Network counters are 32-bit per interface and wrap. Unsigned subtraction gives the true difference.
    public static func wrappedDelta(new: UInt32, old: UInt32) -> UInt64 {
        UInt64(new &- old)
    }

    /// Physical interfaces only. Tunnels and peer-to-peer links carry traffic already counted on a real interface.
    public static func isCountedInterface(_ name: String) -> Bool {
        name.hasPrefix("en")
    }
}

public final class NetworkReader: ThroughputReading, @unchecked Sendable {
    private let lock = NSLock()
    private var previous: [String: (incoming: UInt32, outgoing: UInt32)] = [:]
    private var lastTime: TimeInterval?

    public init() {}

    public func sample() -> ThroughputSnapshot? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var current: [String: (incoming: UInt32, outgoing: UInt32)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  let raw = entry.pointee.ifa_data else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard ThroughputMath.isCountedInterface(name) else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            current[name] = (data.ifi_ibytes, data.ifi_obytes)
        }
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock {
            defer {
                previous = current
                lastTime = now
            }
            guard let lastTime, now > lastTime else { return nil }
            var incoming: UInt64 = 0, outgoing: UInt64 = 0
            for (name, value) in current {
                guard let old = previous[name] else { continue }
                incoming += ThroughputMath.wrappedDelta(new: value.incoming, old: old.incoming)
                outgoing += ThroughputMath.wrappedDelta(new: value.outgoing, old: old.outgoing)
            }
            let seconds = now - lastTime
            return ThroughputSnapshot(incoming: Double(incoming) / seconds, outgoing: Double(outgoing) / seconds)
        }
    }
}

public final class DiskReader: ThroughputReading, @unchecked Sendable {
    private let lock = NSLock()
    private var previous: (read: UInt64, written: UInt64)?
    private var lastTime: TimeInterval?

    public init() {}

    public func sample() -> ThroughputSnapshot? {
        guard let current = Self.totals() else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock {
            defer {
                previous = current
                lastTime = now
            }
            guard let previous, let lastTime else { return nil }
            let seconds = now - lastTime
            return ThroughputSnapshot(
                incoming: ThroughputMath.rate(new: current.read, old: previous.read, seconds: seconds),
                outgoing: ThroughputMath.rate(new: current.written, old: previous.written, seconds: seconds)
            )
        }
    }

    private static func totals() -> (read: UInt64, written: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0, found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let statistics = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            read += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            found = true
        }
        return found ? (read, written) : nil
    }
}
