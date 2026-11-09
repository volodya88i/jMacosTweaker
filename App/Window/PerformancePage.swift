import Core
import SwiftUI

struct PerformancePage: View {
    let context: AppContext

    private var store: MonitorStore { context.store }

    var body: some View {
        PageScroll {
            HStack(alignment: .top, spacing: 14) {
                Card { CPUDetail(model: store.cpu, frequency: store.frequency) }
                Card { MemoryDetail(model: store.memory) }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 14) {
                if store.availability.hasGPU {
                    Card { GPUDetail(model: store.gpu, frequency: store.frequency) }
                }
                Card { ThroughputDetail(kind: .network, model: store.network) }
                Card { ThroughputDetail(kind: .disk, model: store.disk) }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 14) {
                Card { ProcessList(model: store.processes, metric: .cpu) }
                Card { ProcessList(model: store.processes, metric: .memory) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("Processes of other users and of the system need root to read, so only your own are listed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sampling([.cpu, .memory, .gpu, .frequency, .network, .disk], engine: store.engine)
        .sampling([.processes], every: 3, engine: store.engine)
    }
}

/// Header of a detail card: icon, title and the big figure on the right.
private struct DetailHeader: View {
    let symbol: String
    let title: String
    let value: String
    var unit = "%"
    var level = ValueLevel.normal
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            BigValue(value: value, unit: unit, size: compact ? 24 : 28, color: LevelColor.color(level, fallback: .primary))
        }
        .accessibilityElement(children: .combine)
    }
}

struct CPUDetail: View {
    let model: CPUModel
    let frequency: FrequencyModel
    var compact = false

    var body: some View {
        let current = model.current
        VStack(alignment: .leading, spacing: 10) {
            DetailHeader(symbol: "cpu", title: String(localized: "CPU"), value: wholePercent(current?.usage), compact: compact)
            Sparkline(history: model.history, height: compact ? 30 : 40)
            if let current {
                CoreBars(cores: current.cores).frame(height: compact ? 26 : 34)
                InfoRows(items: rows(current))
            }
        }
    }

    private func rows(_ current: CPUSnapshot) -> [InfoRows.Item] {
        var items = [
            InfoRows.Item(title: String(localized: "User"), value: Format.percent(current.user)),
            InfoRows.Item(title: String(localized: "System"), value: Format.percent(current.system))
        ]
        if let usage = current.clusterUsage(.performance) {
            items.append(.init(title: String(localized: "Performance cores"), value: clusterText(usage, frequency.current?.performanceMHz)))
        }
        if let usage = current.clusterUsage(.efficiency) {
            items.append(.init(title: String(localized: "Efficiency cores"), value: clusterText(usage, frequency.current?.efficiencyMHz)))
        }
        return items
    }

    private func clusterText(_ usage: Double, _ mhz: Double?) -> String {
        mhz.map { "\(Format.percent(usage)) · \(Format.megahertz($0))" } ?? Format.percent(usage)
    }
}

/// One rounded bar per core. Efficiency cores use a lighter tint, as a legend under the bars says.
private struct CoreBars: View {
    let cores: [CPUCoreLoad]
    @Environment(\.dataTint) private var tint

    var body: some View {
        Canvas { context, size in
            guard !cores.isEmpty else { return }
            let gap: CGFloat = 3
            let width = (size.width - gap * CGFloat(cores.count - 1)) / CGFloat(cores.count)
            for (index, core) in cores.enumerated() {
                let x = CGFloat(index) * (width + gap)
                let track = Path(roundedRect: CGRect(x: x, y: 0, width: width, height: size.height), cornerRadius: min(width / 2, 3))
                context.fill(track, with: .color(.secondary.opacity(0.18)))
                let height = max(size.height * CGFloat(min(max(core.usage, 0), 1)), 2)
                let fill = Path(roundedRect: CGRect(x: x, y: size.height - height, width: width, height: height), cornerRadius: min(width / 2, 3))
                context.fill(fill, with: .color(core.kind == .efficiency ? tint.opacity(0.5) : tint))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Per-core load, \(cores.count) cores"))
    }
}

struct MemoryDetail: View {
    let model: MemoryModel
    var compact = false

    var body: some View {
        let current = model.current
        let level: ValueLevel = switch current?.pressure {
        case .warning: .warning
        case .critical: .critical
        default: .normal
        }
        VStack(alignment: .leading, spacing: 10) {
            DetailHeader(symbol: "memorychip", title: String(localized: "Memory"), value: wholePercent(current?.usage), level: level, compact: compact)
            if let current {
                let parts = Self.parts(current)
                StackedBar(parts: parts, total: Double(current.total), height: compact ? 8 : 10)
                Legend(parts: parts)
                if compact {
                    InfoRows(items: [
                        .init(title: String(localized: "Used"), value: "\(Format.gigabytes(current.used)) of \(Format.gigabytes(current.total)) GB"),
                        .init(title: String(localized: "Pressure"), value: current.pressure.title, color: level == .normal ? nil : LevelColor.color(level, fallback: .secondary))
                    ])
                } else {
                    Sparkline(history: model.history, tint: level == .normal ? nil : LevelColor.color(level, fallback: .accentColor), height: 40)
                    InfoRows(items: [
                        .init(title: String(localized: "Used"), value: "\(Format.gigabytes(current.used)) of \(Format.gigabytes(current.total)) GB"),
                        .init(title: String(localized: "App"), value: "\(Format.gigabytes(current.app)) GB"),
                        .init(title: String(localized: "Wired"), value: "\(Format.gigabytes(current.wired)) GB"),
                        .init(title: String(localized: "Compressed"), value: "\(Format.gigabytes(current.compressed)) GB"),
                        .init(title: String(localized: "Cached files"), value: "\(Format.gigabytes(current.cached)) GB"),
                        .init(title: String(localized: "Swap"), value: "\(Format.gigabytes(current.swapUsed)) GB"),
                        .init(title: String(localized: "Pressure"), value: current.pressure.title, color: level == .normal ? nil : LevelColor.color(level, fallback: .secondary))
                    ])
                }
            }
        }
    }

    static func parts(_ current: MemorySnapshot) -> [StackedBar.Part] {
        [
            .init(title: String(localized: "App"), value: Double(current.app), color: .blue),
            .init(title: String(localized: "Wired"), value: Double(current.wired), color: .orange),
            .init(title: String(localized: "Compressed"), value: Double(current.compressed), color: .purple),
            .init(title: String(localized: "Cached"), value: Double(current.cached), color: .gray.opacity(0.6))
        ]
    }
}

struct GPUDetail: View {
    let model: GPUModel
    let frequency: FrequencyModel
    var compact = false

    var body: some View {
        let current = model.current
        VStack(alignment: .leading, spacing: 10) {
            DetailHeader(symbol: "square.stack.3d.up", title: String(localized: "GPU"), value: wholePercent(current?.device), compact: compact)
            Sparkline(history: model.history, height: compact ? 30 : 40)
            InfoRows(items: rows(current))
        }
    }

    private func rows(_ current: GPUSnapshot?) -> [InfoRows.Item] {
        var items: [InfoRows.Item] = []
        if let renderer = current?.renderer { items.append(.init(title: String(localized: "Renderer"), value: Format.percent(renderer))) }
        if let tiler = current?.tiler { items.append(.init(title: String(localized: "Tiler"), value: Format.percent(tiler))) }
        if let mhz = frequency.current?.gpuMHz { items.append(.init(title: String(localized: "Average frequency"), value: "≈ \(Format.megahertz(mhz))")) }
        return items
    }
}

struct ThroughputDetail: View {
    enum Kind {
        case network, disk
    }

    let kind: Kind
    let model: ThroughputModel
    var compact = false

    var body: some View {
        let isNetwork = kind == .network
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(isNetwork ? String(localized: "Network") : String(localized: "Disk"), systemImage: isNetwork ? "network" : "internaldrive")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.current.map { Format.rate($0.total) } ?? "–")
                    .font(.system(size: compact ? 18 : 20, weight: .semibold))
                    .monospacedDigit()
            }
            Sparkline(history: model.history, maximum: nil, height: compact ? 30 : 40)
            InfoRows(items: [
                .init(title: isNetwork ? String(localized: "Download") : String(localized: "Read"), value: model.current.map { Format.rate($0.incoming) } ?? "–"),
                .init(title: isNetwork ? String(localized: "Upload") : String(localized: "Write"), value: model.current.map { Format.rate($0.outgoing) } ?? "–")
            ])
        }
    }
}

struct ProcessList: View {
    enum Metric {
        case cpu, memory
    }

    let model: ProcessModel
    let metric: Metric
    var compact = false

    private var rows: [ProcessUsage] {
        (metric == .cpu ? model.current?.byCPU : model.current?.byMemory) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(metric == .cpu ? String(localized: "Top Processes by CPU") : String(localized: "Top Processes by Memory"), systemImage: "list.bullet")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("Measuring…").foregroundStyle(.secondary)
            } else {
                InfoRows(items: rows.map { InfoRows.Item(title: $0.name, value: value($0), color: .primary) })
            }
        }
    }

    private func value(_ process: ProcessUsage) -> String {
        switch metric {
        case .cpu: "\(Int((process.cpu * 100).rounded()))%"
        case .memory: "\(Format.gigabytes(process.memory)) GB"
        }
    }
}
