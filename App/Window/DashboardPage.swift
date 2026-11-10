import Core
import SwiftUI

/// Overview: one status line that answers "is everything OK?", the four load figures, then temperatures, fans and
/// battery.
struct DashboardPage: View {
    let context: AppContext

    private var store: MonitorStore { context.store }

    private var sources: Set<SampleSource> {
        var result: Set<SampleSource> = [.cpu, .memory, .temperatureSummary]
        if store.availability.hasGPU { result.insert(.gpu) }
        if store.availability.hasFans { result.insert(.fans) }
        if store.availability.hasBattery { result.formUnion([.battery, .power]) }
        return result
    }

    var body: some View {
        PageScroll {
            StatusCard(context: context)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
                CPUTile(model: store.cpu)
                if store.availability.hasGPU { GPUTile(model: store.gpu) }
                MemoryTile(model: store.memory)
                if store.availability.hasBattery { PowerTile(model: store.battery) }
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    TemperatureCard(context: context)
                    if store.availability.hasFans {
                        Card {
                            CardHeader(symbol: "fan", title: String(localized: "Fans")) {
                                Text(context.control.helper.status?.fansUnderControl.isEmpty == false
                                     ? context.settings.stored.fan.preset.title : String(localized: "Auto"))
                            }
                            FansGrid(context: context)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                if store.availability.hasBattery {
                    BatteryCard(context: context).frame(maxWidth: .infinity)
                }
            }
        }
        .sampling(sources, engine: store.engine)
    }
}

/// The answer to "is everything OK?", with what the app is doing right now.
struct StatusCard: View {
    let context: AppContext

    var body: some View {
        let status = SystemStatus.line(store: context.store, unit: context.unit)
        let details = context.control.statusDetails()
        Card {
            HStack(spacing: 12) {
                Image(systemName: status.level == .normal ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(status.level == .normal ? .green : LevelColor.color(status.level, fallback: .green))
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.text).font(.title3.weight(.semibold))
                    Text(details.isEmpty ? String(localized: "Fans and charging are under system control.") : details.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CPUTile: View {
    let model: CPUModel

    var body: some View {
        let current = model.current
        MetricTile(
            symbol: "cpu",
            title: String(localized: "CPU"),
            value: wholePercent(current?.usage),
            detail: current.map { String(localized: "\(Int(($0.user * 100).rounded()))% user · \(Int(($0.system * 100).rounded()))% system") } ?? " ",
            history: model.history,
            accessibility: String(localized: "CPU load \(wholePercent(current?.usage)) percent")
        )
    }
}

private struct GPUTile: View {
    let model: GPUModel

    var body: some View {
        let current = model.current
        MetricTile(
            symbol: "square.stack.3d.up",
            title: String(localized: "GPU"),
            value: wholePercent(current?.device),
            detail: current?.renderer.map { String(localized: "Renderer \(Int(($0 * 100).rounded()))%") } ?? " ",
            history: model.history,
            accessibility: String(localized: "GPU load \(wholePercent(current?.device)) percent")
        )
    }
}

private struct MemoryTile: View {
    let model: MemoryModel

    var body: some View {
        let current = model.current
        let level: ValueLevel = switch current?.pressure {
        case .warning: .warning
        case .critical: .critical
        default: .normal
        }
        MetricTile(
            symbol: "memorychip",
            title: String(localized: "Memory"),
            value: wholePercent(current?.usage),
            detail: current.map { String(localized: "\(Format.gigabytes($0.used)) of \(Format.gigabytes($0.total)) GB · \($0.pressure.title)") } ?? " ",
            history: model.history,
            level: level,
            accessibility: String(localized: "Memory use \(wholePercent(current?.usage)) percent")
        )
    }
}

private struct PowerTile: View {
    let model: BatteryModel

    var body: some View {
        let watts = model.flow?.systemWatts
        MetricTile(
            symbol: "bolt",
            title: String(localized: "Power"),
            value: watts.map { String(format: "%.1f", $0) } ?? "–",
            unit: "W",
            detail: String(localized: "System load"),
            history: model.powerHistory,
            maximum: nil,
            accessibility: String(localized: "System power \(Format.watts(watts))")
        )
    }
}
