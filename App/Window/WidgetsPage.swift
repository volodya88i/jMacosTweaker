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
        PageScroll {
            PageHeader(title: WindowSection.widgets.title, detail: String(localized: "Turn on only what you want to see. Modules that are off use no resources.")) {
                Toggle(String(localized: "Combine into one item"), isOn: $settings.stored.combined)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            ForEach(Array(modules.enumerated()), id: \.element.module) { index, config in
                WidgetRow(context: context, config: config, isFirst: index == 0, isLast: index == modules.count - 1)
            }
            Hairline()
            if !context.modulesHiddenByMenuBar.isEmpty {
                ControlNotice(
                    text: String(localized: "No room in the menu bar for: \(context.modulesHiddenByMenuBar.map(\.title).joined(separator: ", ")). Turn some modules off, or combine them."),
                    level: .warning
                )
                .padding(.top, 12)
            }
            Text("If some modules do not appear, the menu bar is full, which is common beside the notch. Turn some off, or combine them.")
                .font(.system(size: 12))
                .foregroundStyle(Color.tkSecondary)
                .padding(.top, 12)
        }
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
    let isFirst: Bool
    let isLast: Bool
    @State private var expanded = false

    private var settings: AppSettings { context.settings }

    private func binding<Value>(_ path: WritableKeyPath<WidgetConfig, Value>) -> Binding<Value> {
        Binding(
            get: { settings.widget(config.module)[keyPath: path] },
            set: { value in settings.updateWidget(config.module) { $0[keyPath: path] = value } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { Hairline() }
            HStack(spacing: 12) {
                Image(systemName: config.module.symbol).frame(width: 18).foregroundStyle(Color.tkSecondary)
                Text(config.module.title)
                Spacer()
                if config.enabled {
                    WidgetPreview(entry: previewEntry, accent: settings.stored.accent == .none ? .labelColor : Tokens.accent(settings.stored.accent))
                        .accessibilityHidden(true)
                    Text(config.style.title).foregroundStyle(Color.tkSecondary)
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.tkSecondary)
                    .accessibilityLabel(String(localized: "Options for \(config.module.title)"))
                }
                moveButton("chevron.left", offset: -1, disabled: isFirst, label: String(localized: "Move \(config.module.title) left"))
                moveButton("chevron.right", offset: 1, disabled: isLast, label: String(localized: "Move \(config.module.title) right"))
                Toggle(config.module.title, isOn: binding(\.enabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .frame(height: Tokens.Size.windowRow)
            if expanded, config.enabled {
                WidgetOptions(context: context, config: config)
                    .padding(.leading, 30)
                    .padding(.bottom, 14)
            }
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

    private func moveButton(_ symbol: String, offset: Int, disabled: Bool, label: String) -> some View {
        Button { settings.moveWidget(config.module, by: offset) } label: {
            Image(systemName: symbol).font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.tkTertiary : Color.tkSecondary)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

private struct WidgetOptions: View {
    let context: AppContext
    let config: WidgetConfig

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
                option(String(localized: "Sensor")) {
                    Picker("", selection: Binding(
                        get: { settings.widget(config.module).pinnedSensor },
                        set: { value in update { $0.pinnedSensor = value } }
                    )) {
                        Text("Hottest").tag(SensorID?.none)
                        ForEach(sensorChoices) { sensor in
                            Text(sensor.name).tag(SensorID?.some(sensor.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
            }
            option(String(localized: "Style")) {
                Picker("", selection: Binding(
                    get: { settings.widget(config.module).style },
                    set: { value in update { $0.style = value } }
                )) {
                    ForEach(config.module.allowedStyles, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            option(String(localized: "Update every")) {
                Picker("", selection: Binding(
                    get: { settings.widget(config.module).interval },
                    set: { value in update { $0.interval = value } }
                )) {
                    ForEach([1.0, 2, 5, 10, 30, 60], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            option(String(localized: "Show")) {
                HStack {
                    Picker("", selection: Binding(
                        get: { ruleKind },
                        set: { kind in update { $0.visibility = rule(kind: kind, value: ruleValue) } }
                    )) {
                        ForEach(ruleKinds, id: \.value) { Text($0.title).tag($0.value) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    if ruleKind == 1 || ruleKind == 2 {
                        TextField("", value: Binding(
                            get: { shown(ruleValue) },
                            set: { value in update { $0.visibility = rule(kind: ruleKind, value: storedValue(value)) } }
                        ), format: .number.precision(.fractionLength(0...1)))
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        Text(unitLabel).foregroundStyle(Color.tkSecondary)
                    }
                }
            }
            option(String(localized: "Warning color at")) {
                ThresholdField(value: settings.widget(config.module).warningAt.map(shown), unit: unitLabel) { value in
                    update { $0.warningAt = value.map(storedValue) }
                }
            }
            option(String(localized: "Critical color at")) {
                ThresholdField(value: settings.widget(config.module).criticalAt.map(shown), unit: unitLabel) { value in
                    update { $0.criticalAt = value.map(storedValue) }
                }
            }
            if config.style != .iconValue {
                option(String(localized: "Small label")) {
                    Toggle("", isOn: Binding(
                        get: { settings.widget(config.module).showsLabel },
                        set: { value in update { $0.showsLabel = value } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
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

    private func option(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(Color.tkSecondary).frame(width: 130, alignment: .leading)
            content()
            Spacer()
        }
    }
}

private struct ThresholdField: View {
    let value: Double?
    let unit: String
    let onChange: @MainActor (Double?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField(String(localized: "Off"), value: Binding(get: { value }, set: { newValue in onChange(newValue) }), format: .number.precision(.fractionLength(0...1)))
                .frame(width: 60)
                .textFieldStyle(.roundedBorder)
            Text(unit).foregroundStyle(Color.tkSecondary)
        }
    }
}
