// READ-ONLY probe of IOHIDEventSystem temperature sensors (private API, resolved at runtime).
import Foundation
import IOKit

typealias Client = CFTypeRef
let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: t) } }

typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Int32
typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
typealias CopyProp = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
typealias FloatVal = @convention(c) (CFTypeRef, Int32) -> Double

guard let create = sym("IOHIDEventSystemClientCreate", Create.self),
      let setM = sym("IOHIDEventSystemClientSetMatching", SetMatching.self),
      let copyS = sym("IOHIDEventSystemClientCopyServices", CopyServices.self),
      let prop = sym("IOHIDServiceClientCopyProperty", CopyProp.self),
      let ev = sym("IOHIDServiceClientCopyEvent", CopyEvent.self),
      let fv = sym("IOHIDEventGetFloatValue", FloatVal.self),
      let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { print("symbols missing"); exit(1) }

for (label, page, usage, evType) in [("temperature", 0xff00, 5, Int64(15)), ("current", 0xff08, 2, Int64(13)), ("voltage", 0xff08, 3, Int64(12))] {
    _ = setM(client, ["PrimaryUsagePage": page, "PrimaryUsage": usage] as CFDictionary)
    let services = (copyS(client)?.takeRetainedValue() as? [CFTypeRef]) ?? []
    print("== \(label): \(services.count) services")
    var rows: [String] = []
    for s in services {
        let name = (prop(s, "Product" as CFString)?.takeRetainedValue() as? String) ?? "?"
        var v = Double.nan
        if let e = ev(s, evType, 0, 0)?.takeRetainedValue() { v = fv(e, Int32(evType << 16)) }
        rows.append("\(name)\t\(String(format: "%.2f", v))")
    }
    rows.sorted().forEach { print($0) }
}
