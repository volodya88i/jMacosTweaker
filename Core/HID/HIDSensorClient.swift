import Foundation
import IOKit

public enum HIDSensorKind: Sendable, CaseIterable {
    case temperature
    case current
    case voltage

    var usagePage: Int { self == .temperature ? 0xFF00 : 0xFF08 }
    var usage: Int {
        switch self {
        case .temperature: 5
        case .current: 2
        case .voltage: 3
        }
    }

    var eventType: Int64 {
        switch self {
        case .temperature: 15
        case .current: 13
        case .voltage: 12
        }
    }
}

public struct HIDServiceReading: Sendable {
    public let name: String
    /// Distinguishes services that share a name. Stable within a boot.
    public let ordinal: Int
    public let value: Double
}

public protocol HIDSensorReading: Sendable {
    func read(kind: HIDSensorKind, ordinals: Set<String>?) -> [HIDServiceReading]
}

/// Private IOHIDEventSystem API, resolved at runtime so a missing symbol degrades instead of failing to launch.
/// Service handles are cached per kind. Reads return raw values, and filtering is the catalog's job.
public final class HIDSensorClient: HIDSensorReading, @unchecked Sendable {
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias FloatValue = @convention(c) (CFTypeRef, Int32) -> Double

    private struct Service {
        let handle: CFTypeRef
        let name: String
        let ordinal: Int
        let identity: String
    }

    private let client: CFTypeRef
    private let setMatching: SetMatching
    private let copyServices: CopyServices
    private let copyProperty: CopyProperty
    private let copyEvent: CopyEvent
    private let floatValue: FloatValue
    private let lock = NSLock()
    private var services: [HIDSensorKind: [Service]] = [:]

    public init?() {
        guard let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: type) }
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: Create.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let floatValue = symbol("IOHIDEventGetFloatValue", as: FloatValue.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        self.client = client
        self.setMatching = setMatching
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.floatValue = floatValue
    }

    /// - Parameter ordinals: identity strings of the form "name#ordinal" to read; nil reads every service.
    public func read(kind: HIDSensorKind, ordinals: Set<String>?) -> [HIDServiceReading] {
        lock.withLock {
            let list = services[kind] ?? discover(kind)
            services[kind] = list
            var result: [HIDServiceReading] = []
            result.reserveCapacity(ordinals?.count ?? list.count)
            for service in list {
                if let ordinals, !ordinals.contains(service.identity) { continue }
                guard let event = copyEvent(service.handle, kind.eventType, 0, 0)?.takeRetainedValue() else { continue }
                let value = floatValue(event, Int32(kind.eventType << 16))
                result.append(HIDServiceReading(name: service.name, ordinal: service.ordinal, value: value))
            }
            return result
        }
    }

    private func discover(_ kind: HIDSensorKind) -> [Service] {
        let matching = ["PrimaryUsagePage": kind.usagePage, "PrimaryUsage": kind.usage] as CFDictionary
        _ = setMatching(client, matching)
        guard let handles = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        var seen: [String: Int] = [:]
        let named = handles.map { handle in
            (handle, (copyProperty(handle, "Product" as CFString)?.takeRetainedValue() as? String) ?? "Unnamed")
        }
        return named.sorted { $0.1 < $1.1 }.map { handle, name in
            let ordinal = seen[name, default: 0]
            seen[name] = ordinal + 1
            return Service(handle: handle, name: name, ordinal: ordinal, identity: "\(name)#\(ordinal)")
        }
    }
}
