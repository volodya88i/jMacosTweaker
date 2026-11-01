import Core
import SwiftUI

struct PerformancePage: View {
    let context: AppContext

    private var store: MonitorStore { context.store }

    var body: some View {
        PageScroll {
            PageHeader(title: WindowSection.performance.title)
            CPUDetail(model: store.cpu, frequency: store.frequency).padding(.top, 20)
            MemoryDetail(model: store.memory).padding(.top, 28)
            if store.availability.hasGPU {
                GPUDetail(model: store.gpu, frequency: store.frequency).padding(.top, 28)
            }
            ThroughputDetail(title: String(localized: "Network"), inLabel: String(localized: "Download"), outLabel: String(localized: "Upload"), model: store.network)
                .padding(.top, 28)
            ThroughputDetail(title: String(localized: "Disk"), inLabel: String(localized: "Read"), outLabel: String(localized: "Write"), model: store.disk)
                .padding(.top, 28)
            ProcessList(title: String(localized: "Top processes by CPU"), model: store.processes, metric: .cpu).padding(.top, 28)
            ProcessList(title: String(localized: "Top processes by memory"), model: store.processes, metric: .memory).padding(.top, 28)
        }
        .sampling([.cpu, .memory, .gpu, .frequency, .network, .disk], engine: store.engine)
        .sampling([.processes], every: 3, engine: store.engine)
    }
}

struct CPUDetail: View {
    let model: CPUModel
    let frequency: FrequencyModel
    var compact = false

    private var rowHeight: CGFloat { compact ? Tokens.Size.panelRow : Tokens.Size.windowRow }

    var body: some View {
        let current = model.current
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU").foregroundStyle(Color.tkSecondary)
                Spacer()
                BigNumber(value: current.map { "\(Int(($0.usage * 100).rounded()))" } ?? "–", unit: "%", size: compact ? 30 : 38)
            }
            Sparkline(history: model.history).padding(.vertical, 10)
            if let current {
                ValueRow(String(localized: "User"), value: Format.percent(current.user), height: rowHeight)
                ValueRow(String(localized: "System"), value: Format.percent(current.system), height: rowHeight)
                if let usage = current.clusterUsage(.performance) {
                    ValueRow(String(localized: "Performance cores"), value: clusterText(usage, frequency.current?.performanceMHz), height: rowHeight)
                }
                if let usage = current.clusterUsage(.efficiency) {
                    ValueRow(String(localized: "Efficiency cores"), value: clusterText(usage, frequency.current?.efficiencyMHz), height: rowHeight)
                }
                Hairline()
                CoreBars(cores: current.cores).padding(.top, 12)
            }
        }
    }

    private func clusterText(_ usage: Double, _ mhz: Double?) -> String {
        mhz.map { "\(Format.percent(usage)) · \(Format.megahertz($0))" } ?? Format.percent(usage)
    }
}

/// One thin bar per core. Efficiency cores use the muted line color.
private struct CoreBars: View {
    let cores: [CPUCoreLoad]
    @Environment(\.lineStyle) private var style

    var body: some View {
        Canvas { context, size in
            guard !cores.isEmpty else { return }
            let gap: CGFloat = 3
            let width = (size.width - gap * CGFloat(cores.count - 1)) / CGFloat(cores.count)
            for (index, core) in cores.enumerated() {
                let x = CGFloat(index) * (width + gap)
                let track = CGRect(x: x, y: 0, width: width, height: size.height)
                context.fill(Path(track), with: .color(.tkTrack))
                let height = size.height * CGFloat(min(max(core.usage, 0), 1))
                let fill = CGRect(x: x, y: size.height - height, width: width, height: height)
                context.fill(Path(fill), with: .color(core.kind == .efficiency ? style.secondaryLine : style.line))
            }
        }
        .frame(height: 40)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Per-core load, \(cores.count) cores"))
    }
}

struct MemoryDetail: View {
    let model: MemoryModel
    var compact = false

    private var rowHeight: CGFloat { compact ? Tokens.Size.panelRow : Tokens.Size.windowRow }

    var body: some View {
        let current = model.current
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory").foregroundStyle(Color.tkSecondary)
                Spacer()
                BigNumber(value: current.map { "\(Int(($0.usage * 100).rounded()))" } ?? "–", unit: "%", size: compact ? 30 : 38)
            }
            Sparkline(history: model.history).padding(.vertical, 10)
            if let current {
                ValueRow(String(localized: "Used"), value: "\(Format.gigabytes(current.used)) of \(Format.gigabytes(current.total)) GB", height: rowHeight)
                ValueRow(String(localized: "App"), value: "\(Format.gigabytes(current.app)) GB", secondary: true, height: rowHeight)
                ValueRow(String(localized: "Wired"), value: "\(Format.gigabytes(current.wired)) GB", secondary: true, height: rowHeight)
                ValueRow(String(localized: "Compressed"), value: "\(Format.gigabytes(current.compressed)) GB", secondary: true, height: rowHeight)
                ValueRow(String(localized: "Cached"), value: "\(Format.gigabytes(current.cached)) GB", secondary: true, height: rowHeight)
                ValueRow(String(localized: "Swap"), value: "\(Format.gigabytes(current.swapUsed)) GB", secondary: true, height: rowHeight)
                ValueRow(String(localized: "Pressure"), value: current.pressure.title, height: rowHeight)
            }
        }
    }
}

struct GPUDetail: View {
    let model: GPUModel
    let frequency: FrequencyModel
    var compact = false

    private var rowHeight: CGFloat { compact ? Tokens.Size.panelRow : Tokens.Size.windowRow }

    var body: some View {
        let current = model.current
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("GPU").foregroundStyle(Color.tkSecondary)
                Spacer()
                BigNumber(value: current.map { "\(Int(($0.device * 100).rounded()))" } ?? "–", unit: "%", size: compact ? 30 : 38)
            }
            Sparkline(history: model.history).padding(.vertical, 10)
            if let renderer = current?.renderer {
                ValueRow(String(localized: "Renderer"), value: Format.percent(renderer), height: rowHeight)
            }
            if let tiler = current?.tiler {
                ValueRow(String(localized: "Tiler"), value: Format.percent(tiler), height: rowHeight)
            }
            if let mhz = frequency.current?.gpuMHz {
                ValueRow(String(localized: "Average frequency"), value: "≈ \(Format.megahertz(mhz))", height: rowHeight)
            }
        }
    }
}

struct ThroughputDetail: View {
    let title: String
    let inLabel: String
    let outLabel: String
    let model: ThroughputModel
    var compact = false

    private var rowHeight: CGFloat { compact ? Tokens.Size.panelRow : Tokens.Size.windowRow }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).foregroundStyle(Color.tkSecondary)
            Sparkline(history: model.history, maximum: nil).padding(.vertical, 10)
            ValueRow(inLabel, value: model.current.map { Format.rate($0.incoming) } ?? "–", height: rowHeight)
            ValueRow(outLabel, value: model.current.map { Format.rate($0.outgoing) } ?? "–", height: rowHeight)
        }
    }
}

struct ProcessList: View {
    enum Metric {
        case cpu, memory
    }

    let title: String
    let model: ProcessModel
    let metric: Metric
    var compact = false

    private var rows: [ProcessUsage] {
        (metric == .cpu ? model.current?.byCPU : model.current?.byMemory) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).foregroundStyle(Color.tkSecondary).padding(.bottom, 10)
            ForEach(rows) { process in
                ValueRow(process.name, value: value(process), height: compact ? Tokens.Size.panelRow : Tokens.Size.windowRow)
            }
            if rows.isEmpty {
                Hairline()
                Text(verbatim: "–").foregroundStyle(Color.tkSecondary).padding(.top, 8)
            }
            if !compact, metric == .memory {
                Text("Only your own processes are listed. System processes need root to read.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.tkSecondary)
                    .padding(.top, 10)
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
