import Core
import SwiftUI

/// Every module can be turned on or off on its own. Off means no menu bar item and no polling.
struct WidgetsPage: View {
    let context: AppContext

    private var settings: AppSettings { context.settings }

    private var modules: [WidgetConfig] {
        settings.stored.widgets.filter { context.store.availability.isAvailable($0.module) }
    }

    /// What the previews need, for as long as this page is open.
    private var previewSources: Set<SampleSource> {
        Set(modules.filter(\.enabled).flatMap(\.module.sources))
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(String(localized: "Combine into one item"), isOn: $settings.stored.combined)
            } footer: {
                Text("One item saves room beside the notch. Each module still keeps its own settings.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(Array(modules.enumerated()), id: \.element.module) { index, config in
                    WidgetRow(context: context, config: config, canMoveUp: index > 0, canMoveDown: index < modules.count - 1)
                }
            } header: {
                Text("Modules")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !context.modulesHiddenByMenuBar.isEmpty {
                        InlineNotice(
                            text: String(localized: "No room in the menu bar for: \(context.modulesHiddenByMenuBar.map(\.title).joined(separator: ", ")). Turn some modules off, or combine them."),
                            level: .warning
                        )
                    }
                    Text("Modules that are off use no resources. The order here is the order in the menu bar.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .sampling(previewSources, every: 2, engine: context.engine)
    }
}

/// The module as it will look in the menu bar, drawn by the same view with the same data.
private struct WidgetPreview: NSViewRepresentable {
    let entry: WidgetView.Entry
    let accent: NSColor

    func makeNSView(context: Context) -> WidgetView { WidgetView() }

    func updateNSView(_ view: WidgetView, context: Context) {
        view.entries = [entry]
        view.accent = accent
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WidgetView, context: Context) -> CGSize? {
        nsView.entries = [entry]
        return CGSize(width: nsView.requiredWidth(), height: 22)
    }
}

private struct WidgetRow: View {
    let context: AppContext
    let config: WidgetConfig
    let canMoveUp: Bool
    let canMoveDown: Bool
    @State private var expanded = false

    private var settings: AppSettings { context.settings }

    private func binding<Value>(_ path: WritableKeyPath<WidgetConfig, Value>) -> Binding<Value> {
        Binding(
            get: { settings.widget(config.module)[keyPath: path] },
            set: { value in settings.updateWidget(config.module) { $0[keyPath: path] = value } }
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded && config.enabled }, set: { expanded = $0 })) {
            WidgetOptions(context: context, config: config, canMoveUp: canMoveUp, canMoveDown: canMoveDown)
                .padding(.vertical, 4)
        } label: {
            HStack(spacing: 10) {
                SettingsIcon(symbol: config.module.symbol, color: config.enabled ? .accentColor : .gray, size: 22)
                Text(config.module.title)
                Spacer()
                if config.enabled {
                    WidgetPreview(entry: previewEntry, accent: Tokens.menuBarAccent(settings.stored.accent))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .accessibilityHidden(true)
                }
                Toggle(config.module.title, isOn: binding(\.enabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
        .contextMenu {
            Button(String(localized: "Move Up")) { settings.moveWidget(config.module, by: -1) }.disabled(!canMoveUp)
            Button(String(localized: "Move Down")) { settings.moveWidget(config.module, by: 1) }.disabled(!canMoveDown)
        }
    }

    private var previewEntry: WidgetView.Entry {
        WidgetView.Entry(
            content: WidgetEvaluator.content(for: config, store: context.store, unit: context.unit),
            style: config.style,
            showsLabel: config.showsLabel,
            history: config.style == .sparkline ? WidgetEvaluator.recentHistory(config.module, store: context.store) : []
        )
    }
}

private struct WidgetOptions: View {
    let context: AppContext
    let config: WidgetConfig
    let canMoveUp: Bool
    let canMoveDown: Bool

    private var settings: AppSettings { context.settings }

    private func update(_ change: (inout WidgetConfig) -> Void) {
        settings.updateWidget(config.module, change)
    }

    private var ruleKinds: [(value: Int, title: String)] {
        var options = [(0, String(localized: "Always")), (1, String(localized: "Above a value")), (2, String(localized: "Below a value"))]
        if context.store.availability.hasBattery {
            options.append((3, String(localized: "While charging")))
            options.append((4, String(localized: "On battery")))
        }
        return options
    }

    private var ruleKind: Int {
        switch config.visibility {
        case .always: 0
        case .above: 1
        case .below: 2
        case .whileCharging: 3
        case .onBattery: 4
        }
    }

    private var isTemperature: Bool { config.module == .temperature }

    /// The short list, plus any sensor pinned from the full list on the Sensors page.
    private var sensorChoices: [SensorDescriptor] {
        let sensors = context.store.sensors
        var choices = sensors.curated.map { SensorDescriptor(id: $0.id, name: $0.name, group: $0.section, kind: .temperature) }
        if let pinned = config.pinnedSensor, !choices.contains(where: { $0.id == pinned }) {
            let name = sensors.descriptors.first { $0.id == pinned }?.name ?? pinned.rawValue
            choices.append(SensorDescriptor(id: pinned, name: name, group: .other, kind: .temperature))
        }
        return choices
    }

    private func shown(_ stored: Double) -> Double {
        isTemperature ? Format.display(celsius: stored, unit: context.unit) : stored
    }

    private func storedValue(_ shown: Double) -> Double {
        isTemperature ? Format.celsius(display: shown, unit: context.unit) : shown
    }

    private var unitLabel: String {
        isTemperature ? context.unit.title : config.module.thresholdUnit
    }

    private var ruleValue: Double {
        switch config.visibility {
        case let .above(value), let .below(value): value
        default: isTemperature ? 70 : 50
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isTemperature {
                Picker(String(localized: "Sensor"), selection: Binding(
                    get: { settings.widget(config.module).pinnedSensor },
                    set: { value in update { $0.pinnedSensor = value } }
                )) {
                    Text("Hottest").tag(SensorID?.none)
                    ForEach(sensorChoices) { sensor in
                        Text(sensor.name).tag(SensorID?.some(sensor.id))
                    }
                }
            }
            Picker(String(localized: "Style"), selection: Binding(
                get: { settings.widget(config.module).style },
                set: { value in update { $0.style = value } }
            )) {
                ForEach(config.module.allowedStyles, id: \.self) { Text($0.title).tag($0) }
            }
            Picker(String(localized: "Update every"), selection: Binding(
                get: { settings.widget(config.module).interval },
                set: { value in update { $0.interval = value } }
            )) {
                ForEach([1.0, 2, 5, 10, 30, 60], id: \.self) { Text("\(Int($0)) s").tag($0) }
            }
            LabeledContent(String(localized: "Show")) {
                HStack {
                    if ruleKind == 1 || ruleKind == 2 {
                        TextField(String(localized: "Value"), value: Binding(
                            get: { shown(ruleValue) },
                            set: { value in
                                guard value.isFinite else { return }
                                update { $0.visibility = rule(kind: ruleKind, value: storedValue(value)) }
                            }
                        ), format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden()
                        .frame(width: 64)
                        Text(unitLabel).foregroundStyle(.secondary)
                    }
                    Picker(String(localized: "Show"), selection: Binding(
                        get: { ruleKind },
                        set: { kind in update { $0.visibility = rule(kind: kind, value: ruleValue) } }
                    )) {
                        ForEach(ruleKinds, id: \.value) { Text($0.title).tag($0.value) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            LabeledContent(String(localized: "Warning color at")) {
                ThresholdField(value: settings.widget(config.module).warningAt.map(shown), unit: unitLabel) { value in
                    update { $0.warningAt = value.map(storedValue) }
                }
            }
            LabeledContent(String(localized: "Critical color at")) {
                ThresholdField(value: settings.widget(config.module).criticalAt.map(shown), unit: unitLabel) { value in
                    update { $0.criticalAt = value.map(storedValue) }
                }
            }
            if config.style != .iconValue {
                Toggle(String(localized: "Small label above the value"), isOn: Binding(
                    get: { settings.widget(config.module).showsLabel },
                    set: { value in update { $0.showsLabel = value } }
                ))
            }
            HStack {
                Spacer()
                Button(String(localized: "Move Up")) { settings.moveWidget(config.module, by: -1) }.disabled(!canMoveUp)
                Button(String(localized: "Move Down")) { settings.moveWidget(config.module, by: 1) }.disabled(!canMoveDown)
            }
            .controlSize(.small)
        }
    }

    private func rule(kind: Int, value: Double) -> VisibilityRule {
        switch kind {
        case 1: .above(value)
        case 2: .below(value)
        case 3: .whileCharging
        case 4: .onBattery
        default: .always
        }
    }
}

private struct ThresholdField: View {
    let value: Double?
    let unit: String
    let onChange: @MainActor (Double?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField(String(localized: "Off"), value: Binding(get: { value }, set: { newValue in onChange(newValue.flatMap { $0.isFinite ? $0 : nil }) }), format: .number.precision(.fractionLength(0...1)))
                .labelsHidden()
                .frame(width: 64)
            Text(unit).foregroundStyle(.secondary)
        }
    }
}
