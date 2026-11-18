import Core
import SwiftUI

struct PerformancePage: View {
    let context: AppContext

    private var store: MonitorStore { context.store }

    var body: some View {
        PageScroll {
            HStack(alignment: .top, spacing: 14) {
                Card(fillsHeight: true) { CPUDetail(model: store.cpu, frequency: store.frequency) }
                Card(fillsHeight: true) { MemoryDetail(model: store.memory) }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 14) {
                if store.availability.hasGPU {
                    Card(fillsHeight: true) { GPUDetail(model: store.gpu, frequency: store.frequency) }
                }
                Card(fillsHeight: true) { ThroughputDetail(kind: .network, model: store.network) }
                Card(fillsHeight: true) { ThroughputDetail(kind: .disk, model: store.disk) }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 14) {
                Card(fillsHeight: true) { ProcessList(model: store.processes, metric: .cpu) }
                Card(fillsHeight: true) { ProcessList(model: store.processes, metric: .memory) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("Processes of other users and of the system need root to read, so only your own are listed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Every 2 s, like the menu bar: once a second doubled the window's CPU time for little visible gain.
        .sampling([.cpu, .memory, .gpu, .frequency, .network, .disk], every: 2, engine: store.engine)
        .sampling([.processes], every: 4, engine: store.engine)
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
                CoreBars(cores: current.cores, compact: compact)
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

/// Per-core load, P-cores and E-cores as two labeled groups. Each group's width follows its core count, so every bar has
/// the same width. Hover a bar for its core and load.
private struct CoreBars: View {
    let cores: [CPUCoreLoad]
    var compact = false

    struct Group: Identifiable {
        let id: String
        let title: String
        let prefix: String
        let cores: [CPUCoreLoad]
        let faded: Bool
    }

    static func groups(_ cores: [CPUCoreLoad]) -> [Group] {
        let performance = cores.filter { $0.kind == .performance }
        let efficiency = cores.filter { $0.kind == .efficiency }
        let other = cores.filter { $0.kind == .unknown }
        var result: [Group] = []
        if !performance.isEmpty {
            result.append(Group(id: "P", title: String(localized: "P-cores"), prefix: "P", cores: performance, faded: false))
        }
        if !efficiency.isEmpty {
            result.append(Group(id: "E", title: String(localized: "E-cores"), prefix: "E", cores: efficiency, faded: true))
        }
        if !other.isEmpty {
            result.append(Group(id: "C", title: String(localized: "Cores"), prefix: "", cores: other, faded: false))
        }
        return result
    }

    var body: some View {
        let groups = Self.groups(cores)
        let total = max(groups.reduce(0) { $0 + $1.cores.count }, 1)
        let gap: CGFloat = 12
        GeometryReader { geometry in
            let available = max(geometry.size.width - gap * CGFloat(max(groups.count - 1, 0)), 1)
            HStack(alignment: .top, spacing: gap) {
                ForEach(groups) { group in
                    CoreGroupView(group: group, compact: compact)
                        .frame(width: available * CGFloat(group.cores.count) / CGFloat(total))
                }
            }
        }
        .frame(height: compact ? 42 : 58)
    }
}

private struct CoreGroupView: View {
    let group: CoreBars.Group
    let compact: Bool
    @Environment(\.dataTint) private var tint

    var body: some View {
        let average = group.cores.reduce(0) { $0 + $1.usage } / Double(max(group.cores.count, 1))
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                ForEach(Array(group.cores.enumerated()), id: \.offset) { index, core in
                    let usage = min(max(core.usage, 0), 1)
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(.secondary.opacity(0.18))
                        .overlay(alignment: .bottom) {
                            // Scaled rather than sized, so a new value redraws the bar without a layout pass.
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(group.faded ? tint.opacity(0.55) : tint)
                                .scaleEffect(x: 1, y: max(usage, 0.04), anchor: .bottom)
                        }
                        .help("\(group.prefix)\(index + 1) · \(Format.percent(usage))")
                }
            }
            .frame(maxHeight: .infinity)
            if !compact {
                HStack(spacing: 3) {
                    ForEach(group.cores.indices, id: \.self) { index in
                        Text("\(index + 1)")
                            .font(.system(size: 8, weight: .medium).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityHidden(true)
            }
            HStack(spacing: 4) {
                Text(group.title).fontWeight(.medium)
                Text("\(group.cores.count)").foregroundStyle(.tertiary)
                Spacer(minLength: 2)
                Text(Format.percent(average)).monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(group.title), \(group.cores.count) cores, average \(Format.percent(average))"))
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
