// READ-ONLY probe: lists IOReport channel groups, then takes a 1 s delta of the Energy Model group.
import Foundation

let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW)
guard h != nil else { print("no libIOReport"); exit(1) }
func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: t) } }

typealias CopyAll = @convention(c) (UInt64, UInt64) -> Unmanaged<CFDictionary>?
typealias CopyGroup = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
typealias CreateSub = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> OpaquePointer?
typealias Sample = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
typealias StrGet = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
typealias IntGet = @convention(c) (CFDictionary, Int32) -> Int64

guard let copyAll = sym("IOReportCopyAllChannels", CopyAll.self),
      let copyGroup = sym("IOReportCopyChannelsInGroup", CopyGroup.self),
      let createSub = sym("IOReportCreateSubscription", CreateSub.self),
      let sample = sym("IOReportCreateSamples", Sample.self),
      let delta = sym("IOReportCreateSamplesDelta", Delta.self),
      let group = sym("IOReportChannelGetGroup", StrGet.self),
      let chName = sym("IOReportChannelGetChannelName", StrGet.self),
      let unit = sym("IOReportChannelGetUnitLabel", StrGet.self),
      let intVal = sym("IOReportSimpleGetIntegerValue", IntGet.self) else { print("symbols missing"); exit(1) }

if let all = copyAll(0, 0)?.takeRetainedValue() as? [String: Any],
   let channels = all["IOReportChannels"] as? [CFDictionary] {
    var counts: [String: Int] = [:]
    for c in channels { counts[(group(c)?.takeUnretainedValue() as String?) ?? "?", default: 0] += 1 }
    print("total channels:", channels.count)
    counts.sorted { $0.key < $1.key }.forEach { print("  \($0.key): \($0.value)") }
}

guard let em = copyGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { print("no energy model"); exit(0) }
let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, em)!
var subbed: Unmanaged<CFMutableDictionary>?
guard let sub = createSub(nil, mutable, &subbed, 0, nil), let subscribed = subbed?.takeRetainedValue() else { print("subscribe failed"); exit(0) }
guard let a = sample(sub, subscribed, nil)?.takeRetainedValue() else { exit(0) }
Thread.sleep(forTimeInterval: 1)
guard let b = sample(sub, subscribed, nil)?.takeRetainedValue(),
      let d = delta(a, b, nil)?.takeRetainedValue() as? [String: Any],
      let rows = d["IOReportChannels"] as? [CFDictionary] else { exit(0) }
print("Energy Model 1 s delta, non-per-core channels:")
for r in rows {
    let n = (chName(r)?.takeUnretainedValue() as String?) ?? "?"
    let u = (unit(r)?.takeUnretainedValue() as String?) ?? "?"
    if n.contains("CORE") || n.contains("Core") { continue }
    let v = intVal(r, 0)
    if v != 0 { print("  \(n)\t\(v) \(u)") }
}
