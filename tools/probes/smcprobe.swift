// READ-ONLY SMC enumeration probe. Only selectors used: read key (5), key info (9), key by index (8).
// Never issues the write selector (6).
import Foundation
import IOKit

// Explicit trailing padding: Swift lays the next field out after size, not stride, unlike C.
struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0; var pad: (UInt8, UInt8, UInt8) = (0, 0, 0) }
struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
struct KeyData {
    var key: UInt32 = 0
    var vers = Vers()
    var pLimit = PLimit()
    var keyInfo = KeyInfo()
    var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
}

func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
func str(_ v: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xff) }, encoding: .isoLatin1) ?? "????"
}

let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
guard service != 0 else { print("no AppleSMC"); exit(1) }
var conn: io_connect_t = 0
let open = IOServiceOpen(service, mach_task_self_, 0, &conn)
print("IOServiceOpen:", String(format: "0x%x", open), "structSize:", MemoryLayout<KeyData>.stride)
guard open == KERN_SUCCESS else { exit(1) }

func call(_ input: inout KeyData) -> (kern_return_t, KeyData) {
    var output = KeyData()
    var size = MemoryLayout<KeyData>.stride
    let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.stride, &output, &size)
    return (r, output)
}
func info(_ key: UInt32) -> KeyInfo? {
    var i = KeyData(); i.key = key; i.data8 = 9
    let (r, o) = call(&i)
    return r == KERN_SUCCESS && o.result == 0 ? o.keyInfo : nil
}
func read(_ key: UInt32, _ ki: KeyInfo) -> [UInt8]? {
    var i = KeyData(); i.key = key; i.data8 = 5; i.keyInfo.dataSize = ki.dataSize
    let (r, o) = call(&i)
    guard r == KERN_SUCCESS, o.result == 0 else { return nil }
    return withUnsafeBytes(of: o.bytes) { Array($0.prefix(Int(min(ki.dataSize, 32)))) }
}
func decode(_ b: [UInt8], _ type: String) -> String {
    let hex = b.map { String(format: "%02x", $0) }.joined()
    switch type {
    case "flt " where b.count == 4:
        let v = b.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }
        return "\(v)"
    case "ui8 " where b.count == 1: return "\(b[0])"
    case "ui16" where b.count == 2: return "\(UInt16(b[0]) << 8 | UInt16(b[1]))"
    case "ui32" where b.count == 4: return "\(b.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })"
    case "flag" where b.count == 1: return b[0] != 0 ? "true" : "false"
    default: return "0x" + hex
    }
}

var total = 0
if let ki = info(fourCC("#KEY")), let b = read(fourCC("#KEY"), ki) {
    total = Int(b.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
}
print("#KEY count:", total)
for idx in 0..<total {
    var i = KeyData(); i.data8 = 8; i.data32 = UInt32(idx)
    let (r, o) = call(&i)
    guard r == KERN_SUCCESS, o.result == 0 else { continue }
    guard let ki = info(o.key) else { print(str(o.key), "NOINFO"); continue }
    let t = str(ki.dataType)
    let val = read(o.key, ki).map { decode($0, t) } ?? "UNREADABLE"
    print("\(str(o.key))\t\(t)\t\(ki.dataSize)\t\(String(format: "%02x", ki.dataAttributes))\t\(val)")
}
IOServiceClose(conn)
