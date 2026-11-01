import AppKit
import Core
import Shared
import SwiftUI
import UniformTypeIdentifiers

struct FansPage: View {
    let context: AppContext

    private var control: ControlModel { context.control }
    private var fanSettings: FanSettings { context.settings.stored.fan }
    private var store: MonitorStore { context.store }
    private var blockReason: String? { control.fanBlockReason }

    private var headerDetail: String {
        if let reason = control.helper.status?.supervisorReason {
            return String(localized: "Thermal protection active: \(reason)")
        }
        if control.isStartingFans { return String(localized: "Starting manual control…") }
        return control.helper.status?.fansUnderControl.isEmpty == false
            ? String(localized: "Controlled by jMacosTweaker")
            : String(localized: "Controlled by the system")
    }

    /// The curve on show. Built-in curves are read-only, and editing one starts a Custom curve from it.
    private var shownCurve: FanCurve? {
        fanSettings.preset == .custom ? fanSettings.customCurve : fanSettings.preset.curve
    }

    private var controlTemperature: Double? {
        let summary = store.sensors.summary
        switch fanSettings.sensor {
        case .cpuAverage: return summary?.cpuAverage
        case .cpuHottest: return summary?.cpuHottest
        case .gpu: return summary?.gpu
        case .ssd: return summary?.ssd
        case .battery: return summary?.battery
        case .hottest, .custom: return summary?.hottest
        }
    }

    var body: some View {
        PageScroll {
            PageHeader(title: WindowSection.fans.title, detail: headerDetail) {
                RestoreButton(control: control)
            }
            if let reason = blockReason {
                ControlNotice(text: reason).padding(.top, 14)
                if control.helper.state != .running, control.helper.state != .checking {
                    CommandLineView(command: control.installCommand).padding(.top, 8)
                } else if control.isUnverifiedOnly {
                    CommandLineView(command: control.testInstallCommand).padding(.top, 8)
                }
            } else {
                controls
            }
            if let error = control.helper.lastError {
                ControlNotice(text: error, level: .warning).padding(.top, 10)
            }
            SectionLabel("Speed").padding(.top, 22)
            ForEach(store.fans.current, id: \.index) { fan in
                FanRow(fan: fan, target: control.helper.status?.targets[fan.index])
            }
            Hairline()
            if store.fans.current.contains(where: { $0.actualRPM == 0 }), control.helper.status?.fansUnderControl.isEmpty != false {
                Text("Stopped fans are normal: macOS can turn them off at low load.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.tkSecondary)
                    .padding(.top, 10)
            }
        }
        .sampling([.fans, .temperatureSummary], engine: store.engine)
        .task { await control.refresh() }
    }

    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if fanSettings.linked {
                FanPresetPicker(control: control)
            } else {
                ForEach(0..<store.availability.fanCount, id: \.self) { fan in
                    HStack {
                        Text("Fan \(fan + 1)").frame(width: 60, alignment: .leading)
                        FanPresetPicker(control: control, fan: fan)
                    }
                }
            }
            if store.availability.fanCount > 1 {
                Toggle(String(localized: "Same setting for all fans"), isOn: Binding(
                    get: { fanSettings.linked },
                    set: { control.setLinked($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            if fanSettings.preset == .constant {
                HStack {
                    Text("Speed")
                    Slider(
                        value: Binding(get: { fanSettings.constantPercent }, set: { control.setConstant(percent: $0) }),
                        in: 0...100,
                        step: 5
                    )
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Constant fan speed"))
                    Text(constantLabel).monospacedDigit().frame(width: 120, alignment: .trailing)
                }
            }
            if let curve = shownCurve {
                HStack {
                    Text("Follow")
                    Picker("", selection: Binding(get: { fanSettings.sensor }, set: { control.setSensor($0) })) {
                        ForEach(sensorOptions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    Spacer()
                    Button(String(localized: "Import…"), action: importPresets)
                    Button(String(localized: "Export…"), action: exportPreset)
                }
                .buttonStyle(InstrumentButtonStyle())
                CurveEditor(curve: curve, isEditable: true, currentTemperature: controlTemperature) { control.setCustomCurve($0) }
                SavedCurves(control: control, saved: fanSettings.saved)
            }
            if store.availability.hasBattery {
                AutoSwitchRow(context: context)
            }
        }
        .padding(.top, 14)
    }

    /// The slider runs from the fan's hardware minimum to its maximum. Only macOS can stop a fan, in Auto.
    private var constantLabel: String {
        guard let fan = store.fans.current.first else { return "\(Int(fanSettings.constantPercent))%" }
        let rpm = CurveMath.rpm(percent: fanSettings.constantPercent, minimum: fan.minimumRPM, maximum: fan.maximumRPM)
        let text = "\(Format.rpm(rpm)) rpm"
        return fanSettings.constantPercent == 0 ? String(localized: "\(text) (minimum)") : text
    }

    private var sensorOptions: [(ControlSensor, String)] {
        let summary = store.sensors.summary
        var options: [(ControlSensor, String)] = [(.hottest, String(localized: "Hottest sensor"))]
        if summary?.cpuHottest != nil {
            options.append((.cpuHottest, String(localized: "CPU hottest")))
            options.append((.cpuAverage, String(localized: "CPU average")))
        }
        if summary?.gpu != nil { options.append((.gpu, String(localized: "GPU"))) }
        if summary?.ssd != nil { options.append((.ssd, String(localized: "SSD"))) }
        if summary?.battery != nil { options.append((.battery, String(localized: "Battery"))) }
        return options
    }

    private func exportPreset() {
        guard let curve = shownCurve else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(fanSettings.preset.title).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let preset = NamedPreset(name: fanSettings.preset.title, curve: curve, sensor: fanSettings.sensor)
        if let data = try? PresetFile.encode([preset]) { try? data.write(to: url, options: .atomic) }
    }

    private func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        if case let .success(presets) = PresetFile.decode(data) {
            let names = Set(presets.map(\.name))
            context.settings.stored.fan.saved.removeAll { names.contains($0.name) }
            context.settings.stored.fan.saved.append(contentsOf: presets)
        } else {
            NSSound.beep()
        }
    }
}

/// Named curves. Click to use, right-click to rename or delete.
private struct SavedCurves: View {
    let control: ControlModel
    let saved: [NamedPreset]
    @State private var isSaving = false
    @State private var renaming: String?
    @State private var name = ""

    var body: some View {
        HStack(spacing: 8) {
            Text("Saved").foregroundStyle(Color.tkSecondary)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(saved, id: \.name) { preset in
                        Button(preset.name) { control.applySavedCurve(preset) }
                            .contextMenu {
                                Button(String(localized: "Rename…")) {
                                    name = preset.name
                                    renaming = preset.name
                                }
                                Button(String(localized: "Delete"), role: .destructive) { control.deleteCurve(preset.name) }
                            }
                    }
                }
            }
            .scrollIndicators(.hidden)
            Button(String(localized: "Save curve…")) {
                name = ""
                isSaving = true
            }
        }
        .buttonStyle(InstrumentButtonStyle())
        .alert(String(localized: "Save curve"), isPresented: $isSaving) {
            TextField(String(localized: "Name"), text: $name)
            Button(String(localized: "Save")) { control.saveCurve(named: name) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .alert(String(localized: "Rename curve"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(String(localized: "Name"), text: $name)
            Button(String(localized: "Rename")) {
                if let renaming { control.renameCurve(renaming, to: name) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
    }
}

private struct AutoSwitchRow: View {
    let context: AppContext

    private var fan: FanSettings { context.settings.stored.fan }

    private var presets: [FanPreset] { [.system, .silent, .balanced, .performance, .maximum] }

    var body: some View {
        HStack(spacing: 12) {
            Toggle(String(localized: "Switch by power source"), isOn: Binding(
                get: { fan.switchByPowerSource },
                set: { context.settings.stored.fan.switchByPowerSource = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            if fan.switchByPowerSource {
                Spacer()
                picker(String(localized: "Adapter"), \.presetOnAdapter)
                picker(String(localized: "Battery"), \.presetOnBattery)
            }
        }
    }

    private func picker(_ title: String, _ path: WritableKeyPath<FanSettings, FanPreset>) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(Color.tkSecondary)
            Picker("", selection: Binding(
                get: { context.settings.stored.fan[keyPath: path] },
                set: { context.settings.stored.fan[keyPath: path] = $0 }
            )) {
                ForEach(presets, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)
        }
    }
}

private struct FanRow: View {
    let fan: FanSnapshot
    let target: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Hairline()
            HStack(alignment: .firstTextBaseline) {
                Text("Fan \(fan.index + 1)").foregroundStyle(Color.tkSecondary)
                Spacer()
                if let target {
                    Text("Target \(Format.rpm(target))").font(.system(size: 12)).foregroundStyle(Color.tkSecondary).monospacedDigit()
                }
                if fan.actualRPM == 0 {
                    BigNumber(value: String(localized: "Stopped"))
                } else {
                    BigNumber(value: Format.rpm(fan.actualRPM), unit: "rpm")
                }
            }
            .padding(.top, 8)
            MeterBar(fraction: fan.maximumRPM > 0 ? fan.actualRPM / fan.maximumRPM : 0)
            HStack {
                Text("Min \(Format.rpm(fan.minimumRPM))")
                Spacer()
                Text("Max \(Format.rpm(fan.maximumRPM))")
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.tkSecondary)
            .monospacedDigit()
        }
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }
}
