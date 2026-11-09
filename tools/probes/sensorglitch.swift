// READ-ONLY. Counts the distinct values each Tp0*, Ts0* and Ta0* key reports over time. On Mac16,8 with macOS 27.2
// (2026-11-09) it showed Tp0* cycling through fixed placeholders (40.0, -4.0, 0.0, 1.5, 2.2, 5.2 °C) and Ta0* stuck at
// 0.0 or 8.3 °C, while Ts0* moves like a real sensor. Issues no SMC write. Build from the repo root:
//   mkdir -p /tmp/sg && cp tools/probes/sensorglitch.swift /tmp/sg/main.swift
//   swiftc -O -o /tmp/sg/probe /tmp/sg/main.swift Core/SMC/*.swift Core/Sensors/SensorCatalog.swift Core/Sensors/SensorSampler.swift Core/HID/HIDSensorClient.swift
//   /tmp/sg/probe 60
// It reads keys directly, because SensorSampler now filters these values out.
import Foundation
guard let smc = try? SMCConnection() else { print("AppleSMC unavailable"); exit(1) }
let count = (try? smc.keyCount()) ?? 0
var keys: [SMCKey] = []
for i in 0..<count { if let k = try? smc.key(at: i), k.description.hasPrefix("Tp0") || k.description.hasPrefix("Ts0") || k.description.hasPrefix("Ta0") { keys.append(k) } }
var distinct: [String: [Double: Int]] = [:]
let end = Date().addingTimeInterval(Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20)
while Date() < end {
    for k in keys { if let v = smc.number(k) { distinct[k.description, default: [:]][(v * 10).rounded() / 10, default: 0] += 1 } }
    Thread.sleep(forTimeInterval: 0.1)
}
for (k, m) in distinct.sorted(by: { $0.key < $1.key }) {
    let top = m.sorted { $0.value > $1.value }.prefix(6).map { String(format: "%.1f×%d", $0.key, $0.value) }.joined(separator: " ")
    print(k, "distinct:", m.count, top)
}
