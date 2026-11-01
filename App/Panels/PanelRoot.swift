import Core
import AppKit
import SwiftUI

/// Content of the panel under a status item: one module's detail, or the overview for the combined item.
struct PanelRoot: View {
    let context: AppContext
    let module: Module?

    private var store: MonitorStore { context.store }

    private var sources: Set<SampleSource> {
        switch module {
        case .cpu: [.cpu, .frequency]
        case .memory: [.memory]
        case .gpu: [.gpu, .frequency]
        case .temperature: [.temperatureFull]
        case .fans: [.fans, .temperatureSummary]
        case .battery, .power: [.battery, .power]
        case .network: [.network]
        case .disk: [.disk]
        case nil:
            [.cpu, .memory, .gpu, .temperatureSummary, .fans, .battery, .power]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
            HStack(spacing: 8) {
                Button(String(localized: "Open window")) {
                    context.openWindow(section)
                }
                .buttonStyle(InstrumentButtonStyle(primary: true))
                RestoreButton(control: context.control, short: true)
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power").font(.system(size: 12))
                }
                .buttonStyle(InstrumentButtonStyle())
                .help(String(localized: "Quit jMacosTweaker"))
                .accessibilityLabel(String(localized: "Quit jMacosTweaker"))
            }
        }
        .padding(16)
        .font(.system(size: 13))
        .foregroundStyle(Color.tkPrimary)
        .environment(\.lineStyle, LineStyle(accent: context.settings.stored.accent, accentDividers: context.settings.stored.accentDividers))
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
            CPUDetail(model: store.cpu, frequency: store.frequency, compact: true)
            ProcessList(title: String(localized: "Top processes"), model: store.processes, metric: .cpu, compact: true)
        case .memory:
            MemoryDetail(model: store.memory, compact: true)
            ProcessList(title: String(localized: "Top processes"), model: store.processes, metric: .memory, compact: true)
        case .network:
            ThroughputDetail(title: String(localized: "Network"), inLabel: String(localized: "Download"), outLabel: String(localized: "Upload"), model: store.network, compact: true)
        case .disk:
            ThroughputDetail(title: String(localized: "Disk"), inLabel: String(localized: "Read"), outLabel: String(localized: "Write"), model: store.disk, compact: true)
        case .gpu: GPUDetail(model: store.gpu, frequency: store.frequency, compact: true)
        case .temperature: TemperaturePanel(context: context)
        case .fans: FansPanel(context: context)
        case .battery, .power: BatteryPanel(context: context)
        case nil: OverviewPanel(context: context)
        }
    }
}

private struct OverviewPanel: View {
    let context: AppContext

    var body: some View {
        let store = context.store
        let status = SystemStatus.line(store: store, unit: context.unit)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("jMacosTweaker").fontWeight(.semibold)
                Spacer()
                Text(status.text).foregroundStyle(LevelColor.color(status.level, fallback: .tkSecondary))
            }
            if store.availability.hasBattery { BatteryPanel(context: context) }
            if store.availability.hasFans { FansPanel(context: context) }
            VStack(spacing: 0) {
                LoadRows(context: context)
            }
        }
    }
}

private struct LoadRows: View {
    let context: AppContext

    var body: some View {
        let store = context.store
        let height = Tokens.Size.panelRow
        ValueRow(String(localized: "CPU"), value: rowText(store.cpu.current.map { Format.percent($0.usage) }, store.sensors.summary?.cpuHottest), secondary: true, height: height)
        if store.availability.hasGPU {
            ValueRow(String(localized: "GPU"), value: rowText(store.gpu.current.map { Format.percent($0.device) }, store.sensors.summary?.gpu), secondary: true, height: height)
        }
        if let memory = store.memory.current {
            ValueRow(String(localized: "Memory"), value: "\(Format.gigabytes(memory.used)) of \(Format.gigabytes(memory.total)) GB", secondary: true, height: height)
        }
    }

    private func rowText(_ load: String?, _ celsius: Double?) -> String {
        [load, celsius.map { Format.temperature($0, unit: context.unit) }].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct TemperaturePanel: View {
    let context: AppContext

    var body: some View {
        let hottest = context.store.sensors.summary?.hottest
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Hottest").foregroundStyle(Color.tkSecondary)
                Spacer()
                BigNumber(value: Format.temperature(hottest, unit: context.unit), size: 30)
            }
            Sparkline(history: context.store.sensors.temperatureHistory, maximum: nil).padding(.vertical, 10)
            TemperatureRows(context: context)
        }
    }
}

private struct FansPanel: View {
    let context: AppContext

    var body: some View {
        let model = context.store.fans
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Fans").foregroundStyle(Color.tkSecondary)
                Spacer()
            }
            .padding(.bottom, 8)
            if context.control.fanBlockReason == nil {
                FanPresetPicker(control: context.control, presets: [.system, .silent, .balanced, .maximum]).padding(.bottom, 10)
            }
            FanRows(model: model, height: Tokens.Size.panelRow)
        }
    }
}

private struct BatteryPanel: View {
    let context: AppContext

    var body: some View {
        let model = context.store.battery
        if let battery = model.current {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    BigNumber(value: "\(battery.percent)", unit: "%", size: 30)
                    Spacer()
                    Text(BatteryText.detail(battery, limit: context.control.nativeChargeLimit, flow: model.flow)).foregroundStyle(Color.tkSecondary)
                }
                MeterBar(fraction: Double(battery.percent) / 100, height: 6, marker: context.control.nativeChargeLimit.map { Double($0) / 100 })
                    .padding(.vertical, 12)
                if !context.control.nativeChargeOptions.isEmpty {
                    NativeChargeLimitPicker(control: context.control).padding(.bottom, 10)
                }
                if case let .adapterCharging(_, system, toBattery) = model.flow ?? battery.flow {
                    SplitBar(first: system, second: toBattery)
                        .padding(.bottom, 10)
                        .accessibilityHidden(true)
                }
                PowerFlowRows(flow: model.flow ?? battery.flow, height: Tokens.Size.panelRow)
                AccessoryRows(model: model, height: Tokens.Size.panelRow)
            }
        }
    }
}
