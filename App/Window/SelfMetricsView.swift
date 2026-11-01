#if DEBUG
import Darwin
import SwiftUI

/// The app's own CPU, memory and wakeups. Debug builds only.
struct SelfMetricsView: View {
    @State private var line = ""

    var body: some View {
        Text(line)
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(Color.tkSecondary)
            .task {
                var last = SelfMetrics.read()
                var lastTime = ContinuousClock.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    let now = SelfMetrics.read()
                    let time = ContinuousClock.now
                    let elapsed = (time - lastTime) / .seconds(1)
                    let cpu = Double(now.cpuNanos - last.cpuNanos) / 1e9 / elapsed * 100
                    let wakeups = Double(now.wakeups - last.wakeups) / elapsed
                    line = String(format: "CPU %.2f%%  Footprint %.1f MB  Wakeups %.1f/s", cpu, Double(now.footprint) / 1_048_576, wakeups)
                    last = now
                    lastTime = time
                }
            }
    }
}

enum SelfMetrics {
    struct Sample {
        var cpuNanos: UInt64
        var footprint: UInt64
        var wakeups: UInt64
    }

    static func read() -> Sample {
        var usage = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard status == 0 else { return Sample(cpuNanos: 0, footprint: 0, wakeups: 0) }
        return Sample(
            cpuNanos: usage.ri_user_time + usage.ri_system_time,
            footprint: usage.ri_phys_footprint,
            wakeups: usage.ri_pkg_idle_wkups + usage.ri_interrupt_wkups
        )
    }
}
#endif
