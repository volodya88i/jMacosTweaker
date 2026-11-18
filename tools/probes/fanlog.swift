// READ-ONLY. Records how macOS itself drives the fans: once a second, the hottest CPU or GPU temperature (with the
// app's placeholder filtering) and each fan's actual speed, then prints the median speed per 2 °C step. Used to check
// `CurveMath.macOSFloor` against the real firmware curve. Issues no SMC write.
// Set the app's fan mode to Auto first: a sample taken while a fan is in manual mode is skipped and counted.
// Build from the repo root:
//   mkdir -p /tmp/fl && cp tools/probes/fanlog.swift /tmp/fl/main.swift
//   swiftc -O -o /tmp/fl/probe /tmp/fl/main.swift Core/SMC/*.swift Core/Sensors/SensorCatalog.swift Core/Sensors/SensorSampler.swift Core/HID/HIDSensorClient.swift Core/Fans/FanReader.swift
//   /tmp/fl/probe 600 > fanlog.csv
// The CSV goes to standard output, the summary to standard error.
import Foundation

guard let smc = try? SMCConnection() else { FileHandle.standardError.write(Data("AppleSMC unavailable\n".utf8)); exit(1) }
let sampler = SensorSampler(smc: smc, hid: HIDSensorClient())
_ = sampler.sampleTemperatures(full: false)
let groups = Dictionary(sampler.descriptors().map { ($0.id, $0.group) }, uniquingKeysWith: { first, _ in first })
let fanCount = Int(smc.number(FanKeys.count) ?? 0)
let limits = (0..<fanCount).map { (smc.number(FanKeys.minimum($0)) ?? 0, smc.number(FanKeys.maximum($0)) ?? 1) }
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "600") ?? 600

print("time,hottest,cpu,gpu," + (0..<fanCount).map { "fan\($0)_rpm,fan\($0)_mode" }.joined(separator: ","))
var buckets: [Int: [Double]] = [:]
var manualSkipped = 0
let start = Date()
while Date().timeIntervalSince(start) < seconds {
    let summary = TemperatureSummary.make(readings: sampler.sampleTemperatures(full: false)) { groups[$0] }
    let hottest = [summary.cpuHottest, summary.gpu].compactMap { $0 }.max()
    var row = [String(format: "%.0f", Date().timeIntervalSince(start)), hottest.map { String(format: "%.1f", $0) } ?? "",
               summary.cpuHottest.map { String(format: "%.1f", $0) } ?? "", summary.gpu.map { String(format: "%.1f", $0) } ?? ""]
    var manual = false
    var fan0: Double?
    for fan in 0..<fanCount {
        let rpm = smc.number(FanKeys.actual(fan)) ?? 0
        let mode = smc.number(FanKeys.mode(fan)) ?? -1
        if mode == 1 { manual = true }
        if fan == 0 { fan0 = rpm }
        row += [String(format: "%.0f", rpm), String(format: "%.0f", mode)]
    }
    print(row.joined(separator: ","))
    if manual {
        manualSkipped += 1
    } else if let hottest, let fan0 {
        buckets[Int(hottest / 2) * 2, default: []].append(fan0)
    }
    Thread.sleep(forTimeInterval: 1)
}

var summary = "temperature, samples, median fan 0 rpm, percent of range\n"
for (bucket, values) in buckets.sorted(by: { $0.key < $1.key }) {
    let median = values.sorted()[values.count / 2]
    let (minimum, maximum) = limits.first ?? (0, 1)
    // 0 rpm means stopped, which is below the range this app can command.
    let percent = median <= 0 ? 0 : max(0, (median - minimum) / max(maximum - minimum, 1) * 100)
    summary += String(format: "%d-%d °C, %d, %.0f, %.0f%%\n", bucket, bucket + 2, values.count, median, percent)
}
summary += "skipped while a fan was in manual mode: \(manualSkipped)\n"
FileHandle.standardError.write(Data(summary.utf8))
