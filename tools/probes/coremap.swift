// READ-ONLY sensor-to-core probe. Runs bursts of one busy thread, and samples per-core load and every Tp/Te/Tg key.
// Writes a CSV for analysis. Issues no SMC write. Usage: coremap <seconds> <output.csv>
import Darwin
import Foundation
import IOKit

struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0; var pad: (UInt8, UInt8, UInt8) = (0, 0, 0) }
struct Vers { var a: UInt8 = 0, b: UInt8 = 0, c: UInt8 = 0, d: UInt8 = 0; var e: UInt16 = 0 }
struct PLimit { var a: UInt16 = 0, b: UInt16 = 0; var c: UInt32 = 0, d: UInt32 = 0, e: UInt32 = 0 }
struct KeyData {
    var key: UInt32 = 0; var vers = Vers(); var pLimit = PLimit(); var keyInfo = KeyInfo()
    var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
}
let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
var conn: io_connect_t = 0
guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { exit(1) }
func call(_ i: KeyData) -> KeyData? {
    var i = i; var o = KeyData(); var s = MemoryLayout<KeyData>.stride
    guard IOConnectCallStructMethod(conn, 2, &i, MemoryLayout<KeyData>.stride, &o, &s) == KERN_SUCCESS, o.result == 0 else { return nil }
    return o
}
func name(_ v: UInt32) -> String { String(decoding: [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xff) }, as: UTF8.self) }
func fcc(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
var c = KeyData(); c.key = fcc("#KEY"); c.data8 = 5; c.keyInfo.dataSize = 4
let total = call(c).map { withUnsafeBytes(of: $0.bytes) { Int($0[0]) << 24 | Int($0[1]) << 16 | Int($0[2]) << 8 | Int($0[3]) } } ?? 0
var keys: [UInt32] = []
for idx in 0..<total {
    var i = KeyData(); i.data8 = 8; i.data32 = UInt32(idx)
    guard let o = call(i) else { continue }
    let n = name(o.key)
    guard n.hasPrefix("Tp") || n.hasPrefix("Te") || n.hasPrefix("Tg") else { continue }
    var q = KeyData(); q.key = o.key; q.data8 = 9
    guard let info = call(q), name(info.keyInfo.dataType) == "flt " else { continue }
    keys.append(o.key)
}
func read(_ k: UInt32) -> Float {
    var i = KeyData(); i.key = k; i.data8 = 5; i.keyInfo.dataSize = 4
    guard let o = call(i) else { return .nan }
    return withUnsafeBytes(of: o.bytes) { $0.loadUnaligned(as: Float.self) }
}
func ticks() -> [(busy: UInt32, total: UInt32)] {
    var count: natural_t = 0; var info: processor_info_array_t?; var n: mach_msg_type_number_t = 0
    guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &n) == KERN_SUCCESS, let info else { return [] }
    defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(n) * 4) }
    return (0..<Int(count)).map { core in
        let u = UInt32(bitPattern: info[core * 4]), s = UInt32(bitPattern: info[core * 4 + 1]), i = UInt32(bitPattern: info[core * 4 + 2]), ni = UInt32(bitPattern: info[core * 4 + 3])
        return (u &+ s &+ ni, u &+ s &+ ni &+ i)
    }
}
let seconds = Double(CommandLine.arguments[1]) ?? 180
let out = CommandLine.arguments[2]
final class Flag: @unchecked Sendable { var on = false; var stop = false }
let flag = Flag()
for qos in [QualityOfService.userInteractive, .background] {
    let t = Thread {
        var x = 1.0001
        while !flag.stop {
            if flag.on { for _ in 0..<100000 { x = x * x; if x > 1e100 { x = 1.0001 } } } else { usleep(20000) }
        }
    }
    t.qualityOfService = qos
    t.start()
}
var rows = "t,burst," + (0..<14).map { "c\($0)" }.joined(separator: ",") + "," + keys.map(name).joined(separator: ",") + "\n"
var last = ticks()
let start = Date()
while Date().timeIntervalSince(start) < seconds {
    let t = Date().timeIntervalSince(start)
    flag.on = Int(t).quotientAndRemainder(dividingBy: 12).remainder < 6
    usleep(500000)
    let now = ticks()
    let loads = zip(now, last).map { a, b -> String in
        let tot = a.total &- b.total
        return tot == 0 ? "0" : String(format: "%.2f", Double(a.busy &- b.busy) / Double(tot))
    }
    last = now
    rows += String(format: "%.1f,%d,", t, flag.on ? 1 : 0) + loads.joined(separator: ",") + "," + keys.map { String(format: "%.2f", read($0)) }.joined(separator: ",") + "\n"
}
flag.stop = true
try? rows.write(toFile: out, atomically: true, encoding: .utf8)
print("done", keys.count)
