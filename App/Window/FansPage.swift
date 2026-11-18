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
            : String(localized: "Controlled by macOS")
    }

    /// The curve on show. Built-in curves are read-only, and editing one starts a Custom curve from it.
    private var shownCurve: FanCurve? {
        fanSettings.preset == .custom ? fanSettings.customCurve : nil
    }

    var body: some View {
        PageScroll {
            if let reason = blockReason {
                NoticeCard(
                    symbol: "lock.fill",
                    title: String(localized: "Fan control is read-only"),
                    text: reason,
                    command: commandForBlock
                )
            }
            if let error = control.helper.lastError {
                Card { InlineNotice(text: error, level: .warning) }
            }
            Card {
                CardHeader(symbol: "fan", title: String(localized: "Speed")) { Text(headerDetail) }
                FansGrid(context: context)
                if store.fans.current.contains(where: { $0.actualRPM == 0 }), control.helper.status?.fansUnderControl.isEmpty != false {
                    Text("Stopped fans are normal: macOS turns them off at low load.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            SectionTitle(String(localized: "Mode"))
            Group {
                if fanSettings.linked {
                    PresetGrid(context: context)
                } else {
                    Card {
                        ForEach(0..<store.availability.fanCount, id: \.self) { fan in
                            if fan > 0 { Divider() }
                            LabeledContent(String(localized: "Fan \(fan + 1)")) {
                                FanPresetPicker(control: control, fan: fan).frame(maxWidth: 520)
                            }
                        }
                    }
                }
                options
                if let curve = shownCurve {
                    CurveCard(context: context, curve: curve)
                }
            }
            .disabled(blockReason != nil)
        }
        .sampling([.fans, .temperatureSummary], every: 2, engine: store.engine)
        .task { await control.refresh() }
    }

    private var commandForBlock: String? {
        if control.helper.state != .running, control.helper.state != .checking { return control.installCommand }
        if control.isUnverifiedOnly { return control.testInstallCommand }
        return nil
    }

    @ViewBuilder private var options: some View {
        let showsLink = store.availability.fanCount > 1
        let showsConstant = fanSettings.linked && fanSettings.preset == .constant
        if showsLink || showsConstant || store.availability.hasBattery {
            Card {
                if showsConstant {
                    LabeledContent(String(localized: "Fixed speed")) {
                        HStack(spacing: 10) {
                            Slider(
                                value: Binding(get: { fanSettings.constantPercent }, set: { control.setConstant(percent: $0) }),
                                in: 0...100,
                                step: 5
                            )
                            .accessibilityLabel(String(localized: "Fixed fan speed"))
                            Text(constantLabel).monospacedDigit().foregroundStyle(.secondary).frame(width: 130, alignment: .trailing)
                        }
                        .frame(maxWidth: 420)
                    }
                    Divider()
                }
                if showsLink {
                    Toggle(String(localized: "Same setting for all fans"), isOn: Binding(
                        get: { fanSettings.linked },
                        set: { control.setLinked($0) }
                    ))
                    .toggleStyle(.switch)
                    if store.availability.hasBattery { Divider() }
                }
                if store.availability.hasBattery {
                    AutoSwitchRow(context: context)
                }
            }
        }
    }

    /// The slider runs from the fan's hardware minimum to its maximum. Only macOS can stop a fan, in Auto.
    private var constantLabel: String {
        guard let fan = store.fans.current.first else { return "\(Int(fanSettings.constantPercent))%" }
        let rpm = CurveMath.rpm(percent: fanSettings.constantPercent, minimum: fan.minimumRPM, maximum: fan.maximumRPM)
        let text = "\(Format.rpm(rpm)) rpm"
        return fanSettings.constantPercent == 0 ? String(localized: "\(text) (minimum)") : text
    }
}

// MARK: Presets

/// Every mode as a card with a picture of what it does. The selected one carries the accent outline.
private struct PresetGrid: View {
    let context: AppContext

    var body: some View {
        let selected = context.settings.stored.fan.preset
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            ForEach(FanPreset.offered, id: \.self) { preset in
                PresetCard(
                    preset: preset,
                    curve: preset == .custom ? context.settings.stored.fan.customCurve : nil,
                    constant: context.settings.stored.fan.constantPercent,
                    isSelected: preset == selected
                ) {
                    context.control.select(preset: preset)
                }
            }
        }
    }
}

private struct PresetCard: View {
    let preset: FanPreset
    let curve: FanCurve?
    let constant: Double
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.dataTint) private var tint
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Label(preset.title, systemImage: preset.symbol)
                    .font(.headline)
                    .foregroundStyle(isSelected ? tint : .primary)
                    .lineLimit(1)
                PresetThumbnail(preset: preset, curve: curve, constant: constant, highlighted: isSelected)
                    .frame(height: 30)
                Text(preset.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Tokens.Size.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Size.cardRadius, style: .continuous)
                    .strokeBorder(isSelected ? tint : Color.primary.opacity(0.06), lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Size.cardRadius))
            .opacity(isEnabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.title)
        .accessibilityHint(preset.caption)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The shape of a mode over 30 to 100 °C: a curve, a flat line, or a dashed line for macOS's own control.
private struct PresetThumbnail: View {
    let preset: FanPreset
    let curve: FanCurve?
    let constant: Double
    let highlighted: Bool

    @Environment(\.dataTint) private var tint

    var body: some View {
        Canvas { context, size in
            let color = highlighted ? tint : Color.secondary
            func y(_ percent: Double) -> CGFloat { size.height - 2 - CGFloat(percent / 100) * (size.height - 4) }
            var path = Path()
            switch preset {
            case .system:
                path.move(to: CGPoint(x: 0, y: y(20)))
                path.addCurve(to: CGPoint(x: size.width, y: y(70)), control1: CGPoint(x: size.width * 0.5, y: y(15)), control2: CGPoint(x: size.width * 0.6, y: y(75)))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                return
            case .maximum:
                path.move(to: CGPoint(x: 0, y: y(100)))
                path.addLine(to: CGPoint(x: size.width, y: y(100)))
            case .constant:
                path.move(to: CGPoint(x: 0, y: y(constant)))
                path.addLine(to: CGPoint(x: size.width, y: y(constant)))
            default:
                guard let curve, let first = curve.points.first else { return }
                func x(_ temperature: Double) -> CGFloat { CGFloat((min(max(temperature, 30), 100) - 30) / 70) * size.width }
                path.move(to: CGPoint(x: 0, y: y(first.percent)))
                for point in curve.points { path.addLine(to: CGPoint(x: x(point.temperature), y: y(point.percent))) }
                path.addLine(to: CGPoint(x: size.width, y: y(curve.points.last?.percent ?? 100)))
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: Curve

private struct CurveCard: View {
    let context: AppContext
    let curve: FanCurve

    private var control: ControlModel { context.control }
    private var fanSettings: FanSettings { context.settings.stored.fan }

    private var controlTemperature: Double? {
        let summary = context.store.sensors.summary
        switch fanSettings.sensor {
        case .cpuAverage: return summary?.cpuAverage
        case .cpuHottest: return summary?.cpuHottest
        case .gpu: return summary?.gpu
        case .ssd: return summary?.ssd
        case .battery: return summary?.battery
        case .hottest, .custom: return summary?.hottest
        }
    }

    private var sensorOptions: [(ControlSensor, String)] {
        let summary = context.store.sensors.summary
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

    var body: some View {
        Card {
            HStack {
                if let name = control.activeSavedCurve {
                    Text(String(localized: "Curve “\(name)”")).font(.headline)
                } else {
                    Text(String(localized: "Custom curve")).font(.headline)
                    Text(String(localized: "not saved")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(String(localized: "Temperature source"), selection: Binding(get: { fanSettings.sensor }, set: { control.setSensor($0) })) {
                    ForEach(sensorOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                .fixedSize()
            }
            CurveEditor(curve: curve, isEditable: true, currentTemperature: controlTemperature, unit: context.unit) { control.setCustomCurve($0) }
            Text(String(localized: "Drag points to edit. Double-click empty space to add a point, or a point to remove it."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            ResponseRow(control: control, response: fanSettings.response)
            Divider()
            SavedCurves(context: context)
        }
    }
}

/// How long a rise must last before fans follow it.
private struct ResponseRow: View {
    let control: ControlModel
    let response: FanResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Response")
                Spacer()
                Picker(String(localized: "Response"), selection: Binding(get: { response }, set: { control.setResponse($0) })) {
                    ForEach(FanResponse.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Text(response.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension FanResponse {
    var title: String {
        switch self {
        case .fast: String(localized: "Fast")
        case .normal: String(localized: "Normal")
        case .calm: String(localized: "Calm")
        }
    }

    var caption: String {
        switch self {
        case .fast: String(localized: "Fans follow a rise after 3 seconds. Short bursts of work are heard.")
        case .normal: String(localized: "Rises shorter than 10 seconds are skipped, so a brief burst of work does not spin fans up.")
        case .calm: String(localized: "Only heat that lasts 30 seconds speeds fans up, and they speed up gently.")
        }
    }
}

/// Named curves. Click to use, right-click to rename or delete. A name already in use asks before replacing.
private struct SavedCurves: View {
    let context: AppContext
    @State private var isSaving = false
    @State private var renaming: String?
    @State private var name = ""
    @State private var pending: PendingReplace?

    /// What waits for the owner to confirm replacing curves of the same name.
    private enum PendingReplace: Identifiable {
        case save(String)
        case rename(from: String, to: String)
        case importing([NamedPreset], clashes: [String])

        var id: String {
            switch self {
            case let .save(name): "save \(name)"
            case let .rename(from, to): "rename \(from) \(to)"
            case let .importing(_, clashes): "import \(clashes.joined(separator: ","))"
            }
        }
    }

    private var control: ControlModel { context.control }
    private var saved: [NamedPreset] { context.settings.stored.fan.saved }

    var body: some View {
        let active = control.activeSavedCurve
        HStack(spacing: 8) {
            Text("Saved").foregroundStyle(.secondary)
            if saved.isEmpty {
                Text("None yet").foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(saved, id: \.name) { preset in
                        Group {
                            if preset.name == active {
                                Button(preset.name) { control.applySavedCurve(preset) }.buttonStyle(.borderedProminent)
                            } else {
                                Button(preset.name) { control.applySavedCurve(preset) }.buttonStyle(.bordered)
                            }
                        }
                        .buttonBorderShape(.capsule)
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
            Menu {
                Button(String(localized: "Save Current Curve…")) {
                    name = active ?? ""
                    isSaving = true
                }
                Divider()
                Button(String(localized: "Import…"), action: importPresets)
                Button(String(localized: "Export Current Curve…"), action: exportPreset)
            } label: {
                Label(String(localized: "Curves"), systemImage: "ellipsis.circle")
            }
            .fixedSize()
        }
        .alert(String(localized: "Save curve"), isPresented: $isSaving) {
            TextField(String(localized: "Name"), text: $name)
            Button(String(localized: "Save")) {
                if control.hasSavedCurve(named: name) {
                    ask(.save(name.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else {
                    control.saveCurve(named: name)
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .alert(String(localized: "Rename curve"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(String(localized: "Name"), text: $name)
            Button(String(localized: "Rename")) {
                guard let old = renaming else { return }
                let new = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if new != old, control.hasSavedCurve(named: new) {
                    ask(.rename(from: old, to: new))
                } else {
                    control.renameCurve(old, to: new)
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .alert(replaceTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { item in
            Button(String(localized: "Replace"), role: .destructive) { replace(item) }
            if case let .importing(presets, clashes) = item {
                Button(String(localized: "Keep Both")) { importKeepingBoth(presets, clashes: clashes) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { item in
            switch item {
            case .save, .rename:
                Text("The saved curve with this name will be replaced. This cannot be undone.")
            case let .importing(_, clashes):
                Text("Already saved: \(clashes.joined(separator: ", ")). Replace them, or keep both with a number added to the imported names.")
            }
        }
    }

    private var replaceTitle: String {
        switch pending {
        case let .save(name), let .rename(_, name): String(localized: "Replace “\(name)”?")
        case let .importing(_, clashes): String(localized: "Replace \(clashes.count) saved curves?")
        case nil: ""
        }
    }

    /// An alert cannot be presented from inside another alert's button, so the question waits for the first to close.
    private func ask(_ item: PendingReplace) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            pending = item
        }
    }

    private func replace(_ item: PendingReplace) {
        switch item {
        case let .save(name):
            control.saveCurve(named: name)
        case let .rename(from, to):
            control.renameCurve(from, to: to)
        case let .importing(presets, _):
            let names = Set(presets.map(\.name))
            context.settings.stored.fan.saved.removeAll { names.contains($0.name) }
            context.settings.stored.fan.saved.append(contentsOf: presets)
        }
    }

    private func importKeepingBoth(_ presets: [NamedPreset], clashes: [String]) {
        var taken = Set(saved.map(\.name))
        for var preset in presets {
            if taken.contains(preset.name) {
                var number = 2
                while taken.contains("\(preset.name) \(number)") { number += 1 }
                preset.name = "\(preset.name) \(number)"
            }
            taken.insert(preset.name)
            context.settings.stored.fan.saved.append(preset)
        }
    }

    private func exportPreset() {
        let fan = context.settings.stored.fan
        let name = control.activeSavedCurve ?? fan.preset.title
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let preset = NamedPreset(name: name, curve: fan.customCurve, sensor: fan.sensor)
        if let data = try? PresetFile.encode([preset]) { try? data.write(to: url, options: .atomic) }
    }

    private func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_000_000,
              let data = try? Data(contentsOf: url) else { return }
        if case let .success(presets) = PresetFile.decode(data) {
            // Curves weaker than macOS are lifted, as everywhere else.
            let valid = presets.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(50).map { preset in
                NamedPreset(name: preset.name, curve: CurveMath.liftedToFloor(preset.curve), sensor: preset.sensor)
            }
            let existing = Set(saved.map(\.name))
            let clashes = valid.map(\.name).filter { existing.contains($0) }
            if clashes.isEmpty {
                context.settings.stored.fan.saved.append(contentsOf: valid)
            } else {
                pending = .importing(Array(valid), clashes: clashes)
            }
        } else {
            NSSound.beep()
        }
    }
}

private struct AutoSwitchRow: View {
    let context: AppContext

    private var fan: FanSettings { context.settings.stored.fan }
    private var presets: [FanPreset] { FanPreset.offered }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(String(localized: "Switch mode by power source"), isOn: Binding(
                get: { fan.switchByPowerSource },
                set: { context.settings.stored.fan.switchByPowerSource = $0 }
            ))
            .toggleStyle(.switch)
            if fan.switchByPowerSource {
                HStack(spacing: 16) {
                    picker(String(localized: "On adapter"), \.presetOnAdapter)
                    picker(String(localized: "On battery"), \.presetOnBattery)
                    Spacer()
                }
            }
        }
    }

    private func picker(_ title: String, _ path: WritableKeyPath<FanSettings, FanPreset>) -> some View {
        Picker(title, selection: Binding(
            get: { context.settings.stored.fan[keyPath: path] },
            set: { context.settings.stored.fan[keyPath: path] = $0 }
        )) {
            ForEach(presets, id: \.self) { Text($0.title).tag($0) }
        }
        .fixedSize()
    }
}
