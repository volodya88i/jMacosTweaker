// READ-ONLY probe: prints IOReport performance-state residencies for CPU and GPU over one second.
import Foundation

let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW)
func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: t) } }
typealias CopyGroup = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
typealias CreateSub = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> OpaquePointer?
typealias Sample = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
typealias StrGet = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
typealias StateCount = @convention(c) (CFDictionary) -> Int32
typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
typealias StateRes = @convention(c) (CFDictionary, Int32) -> Int64
typealias IntGet = @convention(c) (CFDictionary, Int32) -> Int64
guard let copyGroup = sym("IOReportCopyChannelsInGroup", CopyGroup.self), let createSub = sym("IOReportCreateSubscription", CreateSub.self),
      let sample = sym("IOReportCreateSamples", Sample.self), let delta = sym("IOReportCreateSamplesDelta", Delta.self),
      let group = sym("IOReportChannelGetSubGroup", StrGet.self), let chName = sym("IOReportChannelGetChannelName", StrGet.self),
      let unit = sym("IOReportChannelGetUnitLabel", StrGet.self), let count = sym("IOReportStateGetCount", StateCount.self),
      let name = sym("IOReportStateGetNameForIndex", StateName.self), let res = sym("IOReportStateGetResidency", StateRes.self),
      let intVal = sym("IOReportSimpleGetIntegerValue", IntGet.self) else { print("symbols missing"); exit(1) }
for (g, sg) in [("CPU Stats", "CPU Core Performance States"), ("GPU Stats", "GPU Performance States"), ("Energy Model", "")] {
    guard let chans = copyGroup(g as CFString, sg.isEmpty ? nil : sg as CFString, 0, 0, 0)?.takeRetainedValue() else { print("no", g); continue }
    let m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, chans)!
    var s: Unmanaged<CFMutableDictionary>?
    guard let sub = createSub(nil, m, &s, 0, nil), let subscribed = s?.takeRetainedValue(), let a = sample(sub, subscribed, nil)?.takeRetainedValue() else { print("sub failed"); continue }
    Thread.sleep(forTimeInterval: 1)
    guard let b = sample(sub, subscribed, nil)?.takeRetainedValue(), let d = delta(a, b, nil)?.takeRetainedValue() as? [String: Any], let rows = d["IOReportChannels"] as? [CFDictionary] else { continue }
    print("==", g, sg, rows.count)
    var shown = 0
    for r in rows {
        let n = chName(r)?.takeUnretainedValue() as String? ?? "?"
        if g == "Energy Model" {
            let v = intVal(r, 0)
            if !n.contains("CPU") && !n.contains("Core") { continue }
            print(n, v, unit(r)?.takeUnretainedValue() as String? ?? "?", sg)
            continue
        }
        if shown > 24 { continue }
        shown += 1
        let states = (0..<count(r)).map { i in "\(name(r, i)?.takeUnretainedValue() as String? ?? "?")=\(res(r, i))" }
        print(n, states.joined(separator: " "))
    }
}
