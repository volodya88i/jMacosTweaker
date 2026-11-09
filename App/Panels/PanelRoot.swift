import AppKit
import Core
import SwiftUI

/// Content of the popover under a status item: one module's detail, or the overview for the combined item.
struct PanelRoot: View {
    let context: AppContext
    let module: Module?

    private var store: MonitorStore { context.store }

    private var sources: Set<SampleSource> {
        switch module {
        case .cpu: [.cpu, .frequency]
        case .memory: [.memory]
        case .gpu: [.gpu, .frequency]
        case .temperature: [.temperatureSummary]
        case .fans: [.fans, .temperatureSummary]
        case .battery, .power: [.battery, .power]
        case .network: [.network]
        case .disk: [.disk]
        case nil:
            [.cpu, .memory, .gpu, .temperatureSummary, .fans, .battery, .power]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(context: context, module: module, section: section)
            content
            PanelFooter(context: context)
        }
        .padding(14)
        .frame(width: Tokens.Size.panelWidth)
        // The popover takes its height from this content; without this, cards would stretch to fill a guessed height.
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.dataTint, context.dataTint)
        .sampling(sources, engine: store.engine)
        .sampling(module == .cpu || module == .memory ? [.processes] : [], every: 3, engine: store.engine)
        .task { await context.control.refresh() }
    }

    private var section: WindowSection {
        switch module {
        case .cpu, .memory, .gpu, .network, .disk: .performance
        case .temperature: .sensors
        case .fans: .fans
        case .battery, .power: .battery
        case nil: .dashboard
        }
    }

    @ViewBuilder private var content: some View {
        switch module {
        case .cpu:
            Card { CPUDetail(model: store.cpu, frequency: store.frequency, compact: true) }
            Card { ProcessList(model: store.processes, metric: .cpu, compact: true) }
        case .memory:
            Card { MemoryDetail(model: store.memory, compact: true) }
            Card { ProcessList(model: store.processes, metric: .memory, compact: true) }
        case .network:
            Card { ThroughputDetail(kind: .network, model: store.network, compact: true) }
        case .disk:
            Card { ThroughputDetail(kind: .disk, model: store.disk, compact: true) }
        case .gpu:
            Card { GPUDetail(model: store.gpu, frequency: store.frequency, compact: true) }
        case .temperature:
            Card {
                TemperatureChart(context: context)
                Divider()
                TemperatureRows(context: context)
            }
        case .fans:
            FansCard(context: context)
        case .battery, .power:
            PanelBatteryCard(context: context)
        case nil:
            if store.availability.hasFans { FansCard(context: context) }
            LoadGrid(context: context)
            Card {
                CardHeader(symbol: "thermometer.medium", title: String(localized: "Temperature"))
                TemperatureChart(context: context, height: 56)
            }
        }
    }
}

/// App icon, what this popover shows, and one line of status. The buttons open the window.
private struct PanelHeader: View {
    let context: AppContext
    let module: Module?
    let section: WindowSection

    var body: some View {
        let status = SystemStatus.line(store: context.store, unit: context.unit)
        let details = context.control.statusDetails()
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(module?.title ?? "jMacosTweaker").font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(LevelColor.color(status.level, fallback: .green))
                        .frame(width: 7, height: 7)
                    Text(([status.text] + details).joined(separator: " · "))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            Button {
                context.openWindow(section)
            } label: {
                Image(systemName: "macwindow")
            }
            .help(String(localized: "Open jMacosTweaker"))
            .accessibilityLabel(String(localized: "Open jMacosTweaker"))
            .glassIconButton()
            Button {
                context.openWindow(.settings)
            } label: {
                Image(systemName: "gearshape")
            }
            .help(String(localized: "Settings"))
            .accessibilityLabel(String(localized: "Settings"))
            .glassIconButton()
        }
    }
}

private struct PanelFooter: View {
    let context: AppContext

    var body: some View {
        HStack {
            Button {
                context.control.restoreDefaults()
            } label: {
                Label(String(localized: "Restore Defaults"), systemImage: "arrow.uturn.backward")
            }
            .disabled(context.control.helper.state != .running)
            .help(String(localized: "Returns fans and charging to system control"))
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label(String(localized: "Quit"), systemImage: "power")
            }
            .help(String(localized: "Quit jMacosTweaker"))
        }
        .controlSize(.small)
        .glassButton()
    }
}

/// Fans, their mode, and what a curve is following right now.
private struct FansCard: View {
    let context: AppContext

    var body: some View {
        let control = context.control
        Card(padding: 12) {
            FansGrid(context: context, compact: true)
            if control.fanBlockReason == nil {
                FanPresetPicker(control: control, presets: [.system, .silent, .balanced, .maximum])
                if let line = followLine { Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            } else {
                Text(control.helper.state == .running
                     ? String(localized: "Fan control is not available on this Mac.")
                     : String(localized: "Fan control needs the helper. The window explains how to set it up."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var followLine: String? {
        let fan = context.settings.stored.fan
        guard fan.preset.curve != nil || fan.preset == .custom, let summary = context.store.sensors.summary else { return nil }
        let value: Double? = switch fan.sensor {
        case .cpuAverage: summary.cpuAverage
        case .cpuHottest: summary.cpuHottest
        case .gpu: summary.gpu
        case .ssd: summary.ssd
        case .battery: summary.battery
        case .hottest, .custom: summary.hottest
        }
        guard let value else { return nil }
        return String(localized: "Following \(Format.temperature(value, unit: context.unit))")
    }
}

/// CPU, Memory, GPU and Battery or Network as four small tiles.
private struct LoadGrid: View {
    let context: AppContext

    var body: some View {
        let store = context.store
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                MiniTile(symbol: "cpu", title: String(localized: "CPU"), value: wholePercent(store.cpu.current?.usage), unit: "%",
                         detail: store.sensors.summary?.cpuHottest.map { Format.temperature($0, unit: context.unit) } ?? "",
                         fraction: store.cpu.current?.usage)
                let memory = store.memory.current
                MiniTile(symbol: "memorychip", title: String(localized: "Memory"), value: wholePercent(memory?.usage), unit: "%",
                         detail: memory.map { "\(Format.gigabytes($0.used)) GB" } ?? "",
                         fraction: memory?.usage,
                         level: memory?.pressure == .critical ? .critical : memory?.pressure == .warning ? .warning : .normal)
            }
            GridRow {
                if store.availability.hasGPU {
                    MiniTile(symbol: "square.stack.3d.up", title: String(localized: "GPU"), value: wholePercent(store.gpu.current?.device), unit: "%",
                             detail: store.sensors.summary?.gpu.map { Format.temperature($0, unit: context.unit) } ?? "",
                             fraction: store.gpu.current?.device)
                }
                if let battery = store.battery.current {
                    MiniTile(symbol: BatteryText.symbol(battery), title: String(localized: "Battery"), value: "\(battery.percent)", unit: "%",
                             detail: store.battery.flow?.systemWatts.map { String(localized: "\(Format.watts($0)) load") } ?? battery.state.title,
                             fraction: Double(battery.percent) / 100,
                             level: BatteryText.level(battery),
                             tint: .green)
                }
            }
        }
    }
}

private struct MiniTile: View {
    let symbol: String
    let title: String
    let value: String
    let unit: String
    let detail: String
    var fraction: Double?
    var level = ValueLevel.normal
    var tint: Color?

    var body: some View {
        Card(padding: 11) {
            CardHeader(symbol: symbol, title: title) { Text(detail).monospacedDigit() }
            BigValue(value: value, unit: unit, size: 24, color: LevelColor.color(level, fallback: .primary))
            if let fraction {
                CapsuleBar(fraction: fraction, tint: level == .normal ? tint : LevelColor.color(level, fallback: .accentColor), height: 5)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PanelBatteryCard: View {
    let context: AppContext

    var body: some View {
        let model = context.store.battery
        if let battery = model.current {
            Card(padding: 12) {
                BatteryHero(model: model, battery: battery, limit: context.control.nativeChargeLimit, compact: true)
                if !context.control.nativeChargeOptions.isEmpty {
                    LabeledContent(String(localized: "Charge limit")) {
                        NativeChargeLimitPicker(control: context.control).fixedSize()
                    }
                }
                Divider()
                PowerFlowView(flow: model.flow ?? battery.flow)
                AccessoryRows(model: model)
            }
        }
    }
}

extension View {
    /// A round icon button: Liquid Glass on macOS 26 and later, borderless before it.
    @ViewBuilder
    func glassIconButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            buttonStyle(.borderless).font(.title3)
        }
    }
}
