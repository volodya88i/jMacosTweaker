import Core
import SwiftUI

struct SensorsPage: View {
    let context: AppContext
    @State private var search = ""
    @State private var showAll = false

    private var model: SensorsModel { context.store.sensors }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    private func matches(_ descriptor: SensorDescriptor) -> Bool {
        query.isEmpty || descriptor.name.localizedCaseInsensitiveContains(query) || descriptor.group.title.localizedCaseInsensitiveContains(query)
    }

    private var rawGroups: [(group: SensorGroup, rows: [SensorDescriptor])] {
        let matching = model.descriptors.filter(matches)
        return SensorGroup.allCases.compactMap { group in
            let rows = matching.filter { $0.group == group }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return rows.isEmpty ? nil : (group, rows)
        }
    }

    /// Curated rows as ordinary descriptors, so both lists share one row view.
    private var curatedRows: [SensorDescriptor] {
        model.curated.map { SensorDescriptor(id: $0.id, name: $0.name, group: $0.section, kind: .temperature) }.filter(matches)
    }

    private var subtitle: String {
        showAll
            ? String(localized: "\(model.descriptors.count) sensors. Names come from observation, not from Apple.")
            : String(localized: "Groups come from load tests on real hardware, not from Apple.")
    }

    var body: some View {
        List {
            if showAll {
                ForEach(rawGroups, id: \.group) { entry in
                    Section {
                        ForEach(entry.rows) { SensorRow(context: context, descriptor: $0) }
                    } header: {
                        ColumnsHeader(title: entry.group.title)
                    }
                }
            } else {
                Section {
                    ForEach(curatedRows) { SensorRow(context: context, descriptor: $0) }
                } header: {
                    ColumnsHeader(title: String(localized: "Temperature"))
                }
                if !context.store.fans.current.isEmpty, query.isEmpty {
                    Section(String(localized: "Fans")) {
                        ForEach(context.store.fans.current, id: \.index) { fan in
                            HStack {
                                Text("Fan \(fan.index + 1)")
                                Spacer()
                                Text(Format.fanSpeed(fan.actualRPM)).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if model.descriptors.isEmpty {
                ContentUnavailableView(String(localized: "Reading sensors…"), systemImage: "thermometer.medium")
            } else if showAll ? rawGroups.isEmpty : curatedRows.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: String(localized: "Search sensors"))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(String(localized: "Sensors shown"), selection: $showAll) {
                    Text("Main").tag(false)
                    Text("All").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help(String(localized: "Main shows the sensors that matter. All lists every raw sensor."))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.resetStatistics()
                } label: {
                    Label(String(localized: "Reset Min and Max"), systemImage: "arrow.counterclockwise")
                }
                .help(String(localized: "Starts minimum, average and maximum over from now"))
            }
        }
        .sampling(showAll ? [.temperatureFull, .electrical, .fans] : [.temperatureFull, .fans], every: 2, engine: context.engine)
    }
}

private enum Column {
    static let value: CGFloat = 58
    static let now: CGFloat = 66
    static let pin: CGFloat = 26
}

private struct ColumnsHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Group {
                Text("Min").frame(width: Column.value, alignment: .trailing)
                Text("Avg").frame(width: Column.value, alignment: .trailing)
                Text("Max").frame(width: Column.value, alignment: .trailing)
                Text("Now").frame(width: Column.now, alignment: .trailing)
            }
            .foregroundStyle(.secondary)
            Spacer().frame(width: Column.pin)
        }
    }
}

private struct SensorRow: View {
    let context: AppContext
    let descriptor: SensorDescriptor

    private var stats: SensorStats? { context.store.sensors.stats[descriptor.id] }

    private var isStale: Bool {
        guard let stats else { return true }
        return ProcessInfo.processInfo.systemUptime - stats.lastSeen > SensorsModel.staleAfter
    }

    private var isPinned: Bool {
        context.settings.widget(.temperature).pinnedSensor == descriptor.id
    }

    private func text(_ value: Double?) -> String {
        guard let value else { return "–" }
        return Format.sensorValue(value, kind: descriptor.kind, unit: context.unit)
    }

    var body: some View {
        let level = descriptor.kind == .temperature && !isStale ? LevelColor.temperatureLevel(stats?.latest) : .normal
        HStack {
            Text(descriptor.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            Group {
                Text(text(stats?.minimum)).frame(width: Column.value, alignment: .trailing)
                Text(text(stats?.average)).frame(width: Column.value, alignment: .trailing)
                Text(text(stats?.maximum)).frame(width: Column.value, alignment: .trailing)
            }
            .foregroundStyle(.secondary)
            // No current reading: the sensor's cluster is powered down, or it vanished. A dash, not an old value.
            Text(isStale ? "–" : text(stats?.latest))
                .fontWeight(.medium)
                .foregroundStyle(isStale ? Color.secondary : LevelColor.color(level, fallback: .primary))
                .frame(width: Column.now, alignment: .trailing)
            pinButton.frame(width: Column.pin, alignment: .trailing)
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var pinButton: some View {
        if descriptor.kind == .temperature {
            // Read once, outside the update: reading settings while they are being changed is an exclusivity violation.
            let pinned = isPinned
            Button {
                context.settings.updateWidget(.temperature) { config in
                    config.pinnedSensor = pinned ? nil : descriptor.id
                    if !pinned { config.enabled = true }
                }
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .foregroundStyle(pinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Show this sensor in the Temperature menu bar module"))
            .accessibilityLabel(pinned ? String(localized: "Unpin \(descriptor.name)") : String(localized: "Pin \(descriptor.name) to the menu bar"))
        }
    }
}
