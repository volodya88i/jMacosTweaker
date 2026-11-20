import Core
import SwiftUI

/// Every module can be turned on or off on its own. Off means no menu bar item and no polling.
/// Rows expand in place, and the handle on the right drags a module to a new place in the menu bar.
struct WidgetsPage: View {
    let context: AppContext
    @State private var expanded: Set<Module> = Self.initiallyExpanded
    @State private var dragging: Module?

    /// Debug builds take `--expand <module>` so snapshots can show a module's options.
    private static var initiallyExpanded: Set<Module> {
        #if DEBUG
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--expand"), arguments.indices.contains(flag + 1),
           let module = Module(rawValue: arguments[flag + 1]) {
            return [module]
        }
        #endif
        return []
    }

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
        let modules = modules
        PageScroll {
            Card {
                HStack(spacing: 12) {
                    SettingsIcon(symbol: "menubar.rectangle", color: .indigo, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Combine into one item")
                        Text("One item saves room beside the notch. Each module still keeps its own settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle(String(localized: "Combine into one item"), isOn: $settings.stored.combined)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            SectionTitle(String(localized: "Modules"))
            VStack(spacing: 0) {
                ForEach(Array(modules.enumerated()), id: \.element.module) { index, config in
                    if index > 0 { Divider().padding(.leading, 84) }
                    ModuleRow(
                        context: context,
                        config: config,
                        isExpanded: Binding(
                            get: { config.enabled && expanded.contains(config.module) },
                            set: { value in
                                if value { expanded.insert(config.module) } else { expanded.remove(config.module) }
                            }
                        ),
                        isDragging: dragging == config.module,
                        canMoveUp: index > 0,
                        canMoveDown: index < modules.count - 1,
                        onDragStart: { dragging = config.module }
                    )
                    .onDrop(of: [.text], delegate: ModuleDropDelegate(target: config.module, dragging: $dragging, settings: settings))
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Tokens.Size.cardRadius, style: .continuous))
            if !context.modulesHiddenByMenuBar.isEmpty {
                InlineNotice(
                    text: String(localized: "No room in the menu bar for: \(context.modulesHiddenByMenuBar.map(\.title).joined(separator: ", ")). Turn some modules off, or combine them."),
                    level: .warning
                )
            }
            Text("Modules that are off use no resources. Drag a module by its handle to change its place in the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sampling(previewSources, every: 2, engine: context.engine)
    }
}

/// Live reordering: a row makes room as soon as a dragged module passes over it.
private struct ModuleDropDelegate: DropDelegate {
    let target: Module
    @Binding var dragging: Module?
    let settings: AppSettings

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.snappy(duration: 0.25)) { settings.moveWidget(dragging, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

extension Module {
    /// Each module's own color, as in System Settings. Modules that are off turn gray.
    var tint: Color {
        switch self {
        case .cpu: .blue
        case .memory: .green
        case .gpu: .purple
        case .temperature: .orange
        case .fans: .teal
        case .battery: .green
        case .power: .yellow
        case .network: .indigo
        case .disk: .gray
        }
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

private struct ModuleRow: View {
    let context: AppContext
    let config: WidgetConfig
    @Binding var isExpanded: Bool
    let isDragging: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onDragStart: () -> Void

    private var settings: AppSettings { context.settings }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                WidgetOptions(context: context, config: config)
                    .padding(.leading, 46)
                    .padding(.trailing, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
        .opacity(isDragging ? 0.45 : 1)
        .contextMenu {
            Button(String(localized: "Move Up")) { settings.moveWidget(config.module, by: -1) }.disabled(!canMoveUp)
            Button(String(localized: "Move Down")) { settings.moveWidget(config.module, by: 1) }.disabled(!canMoveDown)
        }
        .accessibilityAction(named: String(localized: "Move Up")) { settings.moveWidget(config.module, by: -1) }
        .accessibilityAction(named: String(localized: "Move Down")) { settings.moveWidget(config.module, by: 1) }
    }

    private var header: some View {
        // The chevron sits in its own column, centered between the card's edge and the icon. The whole row expands
        // it, so it is not a small target; the switch and the handle keep their own clicks.
        HStack(spacing: 11) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 24, height: 24)
                .opacity(config.enabled ? 1 : 0.25)
            SettingsIcon(symbol: config.module.symbol, color: config.enabled ? config.module.tint : .gray, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(config.module.title)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if config.enabled {
                WidgetPreview(entry: previewEntry, accent: Tokens.menuBarAccent(settings.stored.accent))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
            }
            Toggle(config.module.title, isOn: Binding(
                get: { config.enabled },
                set: { value in
                    settings.updateWidget(config.module) { $0.enabled = value }
                    if !value { isExpanded = false }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 26, height: 30)
                .contentShape(Rectangle())
                .onDrag {
                    onDragStart()
                    return NSItemProvider(object: config.module.rawValue as NSString)
                }
                .help(String(localized: "Drag to change the order in the menu bar"))
                .accessibilityHidden(true)
        }
        .padding(.leading, 11)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            guard config.enabled else { return }
            withAnimation(.snappy(duration: 0.28)) { isExpanded.toggle() }
        }
        .accessibilityAddTraits(config.enabled ? .isButton : [])
        .accessibilityHint(config.enabled ? String(localized: "Shows the module's options") : "")
    }

    /// What the module does now, in one line, so a collapsed row still says it.
    private var summary: String {
        guard config.enabled else { return String(localized: "Off") }
        var parts = [config.style.title, String(localized: "every \(Int(config.interval)) s")]
        switch config.visibility {
        case .always: break
        case .above: parts.append(String(localized: "above a value"))
        case .below: parts.append(String(localized: "below a value"))
        case .whileCharging: parts.append(String(localized: "while charging"))
        case .onBattery: parts.append(String(localized: "on battery"))
        }
        return parts.joined(separator: " · ")
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

/// A module's options as evenly spaced rows in an inset group, the same height whatever control each row holds.
private struct WidgetOptions: View {
    let context: AppContext
    let config: WidgetConfig

    private var settings: AppSettings { context.settings }

    /// Changes go through a copy in `AppSettings`, and values are worked out before the change, never inside it.
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
        VStack(spacing: 0) {
            if isTemperature {
                OptionRow(String(localized: "Sensor")) {
                    Picker(String(localized: "Sensor"), selection: Binding(
                        get: { config.pinnedSensor },
                        set: { value in update { $0.pinnedSensor = value } }
                    )) {
                        Text("Hottest").tag(SensorID?.none)
                        ForEach(sensorChoices) { sensor in
                            Text(sensor.name).tag(SensorID?.some(sensor.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
            }
            OptionRow(String(localized: "Style")) {
                Picker(String(localized: "Style"), selection: Binding(
                    get: { config.style },
                    set: { value in update { $0.style = value } }
                )) {
                    ForEach(config.module.allowedStyles, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Divider()
            OptionRow(String(localized: "Update every")) {
                Picker(String(localized: "Update every"), selection: Binding(
                    get: { config.interval },
                    set: { value in update { $0.interval = value } }
                )) {
                    ForEach(Module.intervals, id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Divider()
            OptionRow(String(localized: "Show")) {
                HStack(spacing: 6) {
                    if ruleKind == 1 || ruleKind == 2 {
                        let kind = ruleKind
                        TextField(String(localized: "Value"), value: Binding(
                            get: { shown(ruleValue) },
                            set: { value in
                                guard value.isFinite else { return }
                                let rule = rule(kind: kind, value: storedValue(value))
                                update { $0.visibility = rule }
                            }
                        ), format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                        Text(unitLabel).foregroundStyle(.secondary)
                    }
                    Picker(String(localized: "Show"), selection: Binding(
                        get: { ruleKind },
                        set: { kind in
                            let rule = rule(kind: kind, value: ruleValue)
                            update { $0.visibility = rule }
                        }
                    )) {
                        ForEach(ruleKinds, id: \.value) { Text($0.title).tag($0.value) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Divider()
            OptionRow(String(localized: "Warning color at")) {
                ThresholdField(value: config.warningAt.map(shown), unit: unitLabel) { value in
                    let stored = value.map(storedValue)
                    update { $0.warningAt = stored }
                }
            }
            Divider()
            OptionRow(String(localized: "Critical color at")) {
                ThresholdField(value: config.criticalAt.map(shown), unit: unitLabel) { value in
                    let stored = value.map(storedValue)
                    update { $0.criticalAt = stored }
                }
            }
            if config.style != .iconValue {
                Divider()
                OptionRow(String(localized: "Small label above the value")) {
                    Toggle(String(localized: "Small label above the value"), isOn: Binding(
                        get: { config.showsLabel },
                        set: { value in update { $0.showsLabel = value } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

/// One option: title on the left, control on the right, always the same height.
private struct OptionRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            control
        }
        .frame(minHeight: 38)
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
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
            Text(unit).foregroundStyle(.secondary)
        }
    }
}
