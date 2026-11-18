import Foundation

/// What can be sampled. A source with no demand is never read.
public enum SampleSource: String, CaseIterable, Hashable, Sendable {
    case cpu
    case memory
    case gpu
    case temperatureSummary
    case temperatureFull
    case fans
    case battery
    case electrical
    case frequency
    case power
    case network
    case disk
    case processes
}

/// A request to sample some sources at a given interval, held for as long as something is visible.
public struct SampleDemand: Hashable, Sendable {
    public let sources: Set<SampleSource>
    public let interval: TimeInterval

    public init(sources: Set<SampleSource>, interval: TimeInterval) {
        self.sources = sources
        self.interval = interval
    }
}

/// Pure timing logic for the one scheduler timer: which sources are due, and when to wake next.
/// Sources due within `coalesceWindow` of each other are read together, so several rates share one wakeup.
public struct SamplePlan: Sendable {
    public private(set) var intervals: [SampleSource: TimeInterval] = [:]
    private var nextDue: [SampleSource: TimeInterval] = [:]

    public let coalesceWindow: TimeInterval

    public init(coalesceWindow: TimeInterval = 0.25) {
        self.coalesceWindow = coalesceWindow
    }

    /// Recomputes rates from all live demands. The fastest demand wins per source.
    /// A source that speeds up is due at once, so opening a detail view shows fresh data.
    public mutating func update(demands: some Sequence<SampleDemand>, multiplier: Double, now: TimeInterval) {
        var fresh: [SampleSource: TimeInterval] = [:]
        for demand in demands {
            for source in demand.sources {
                fresh[source] = min(fresh[source] ?? .infinity, demand.interval * max(multiplier, 1))
            }
        }
        fresh = Self.aligned(fresh)
        for source in nextDue.keys where fresh[source] == nil {
            nextDue[source] = nil
        }
        for (source, interval) in fresh {
            if let old = intervals[source], let due = nextDue[source], interval >= old {
                nextDue[source] = min(due, now + interval)
            } else {
                nextDue[source] = now
            }
        }
        intervals = fresh
    }

    /// Snaps slower rates to a multiple of the fastest one when that is within a quarter of what was asked. With the menu
    /// bar at 2 s for CPU and 5 s for temperatures, reads used to land at 0, 2, 4, 5, 6, 8 and 10 s: seven wakeups and
    /// redraws where five do, because 5 s becomes 6 s and lands on the 2 s ticks.
    static func aligned(_ intervals: [SampleSource: TimeInterval]) -> [SampleSource: TimeInterval] {
        guard let fastest = intervals.values.min(), fastest > 0 else { return intervals }
        return intervals.mapValues { interval in
            guard interval > fastest else { return interval }
            let snapped = (interval / fastest).rounded(.toNearestOrAwayFromZero) * fastest
            return abs(snapped - interval) <= interval * 0.25 ? snapped : interval
        }
    }

    /// Time of the next needed wakeup, or nil when nothing is demanded and no timer should exist.
    public var nextFire: TimeInterval? {
        nextDue.values.min()
    }

    /// Returns the sources to read now and schedules their next reads.
    public mutating func takeDue(now: TimeInterval) -> Set<SampleSource> {
        var due = Set<SampleSource>()
        for (source, time) in nextDue where time <= now + coalesceWindow {
            due.insert(source)
            nextDue[source] = now + (intervals[source] ?? 1)
        }
        return due
    }

    /// Marks a source due now, for event-driven updates such as a power source change.
    public mutating func expedite(_ source: SampleSource, now: TimeInterval) {
        guard nextDue[source] != nil else { return }
        nextDue[source] = now
    }
}
