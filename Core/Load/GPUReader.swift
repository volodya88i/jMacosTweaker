import Foundation
import IOKit

/// GPU utilization from `IOAccelerator` `PerformanceStatistics`. The service handle is cached.
public final class GPUReader: GPUReading, @unchecked Sendable {
    private let service: io_registry_entry_t

    public init?() {
        let found = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard found != 0 else { return nil }
        service = found
    }

    deinit {
        IOObjectRelease(service)
    }

    public func sample() -> GPUSnapshot? {
        guard let raw = IORegistryEntryCreateCFProperty(
            service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any] else { return nil }
        return Self.parse(raw)
    }

    public static func parse(_ statistics: [String: Any]) -> GPUSnapshot? {
        func fraction(_ key: String) -> Double? {
            guard let value = (statistics[key] as? NSNumber)?.doubleValue, value >= 0, value <= 100 else { return nil }
            return value / 100
        }
        guard let device = fraction("Device Utilization %") else { return nil }
        return GPUSnapshot(device: device, renderer: fraction("Renderer Utilization %"), tiler: fraction("Tiler Utilization %"))
    }
}
