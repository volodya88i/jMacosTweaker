import Core
import SwiftUI

struct SensorsPage: View {
    let context: AppContext
    @State private var search = ""
    @State private var showAll = false

    private var model: SensorsModel { context.store.sensors }

    private var rawGroups: [(group: SensorGroup, rows: [SensorDescriptor])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matching = model.descriptors.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.group.title.localizedCaseInsensitiveContains(query)
        }
        return SensorGroup.allCases.compactMap { group in
            let rows = matching.filter { $0.group == group }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return rows.isEmpty ? nil : (group, rows)
        }
    }

    /// Curated rows as ordinary descriptors, so both lists share one row view.
    private var curatedRows: [SensorDescriptor] {
        model.curated.map { SensorDescriptor(id: $0.id, name: $0.name, group: $0.section, kind: .temperature) }
    }

    private var detail: String {
        showAll
            ? String(localized: "\(model.descriptors.count) raw sensors. Names come from observation, not from Apple.")
            : String(localized: "The sensors that matter. Groups come from load tests on real hardware, not from Apple.")
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: WindowSection.sensors.title, detail: detail) {
                HStack(spacing: 12) {
                    if showAll {
                        TextField(String(localized: "Search"), text: $search)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 8)
                            .frame(width: 160, height: 26)
                            .overlay(RoundedRectangle(cornerRadius: Tokens.Size.controlRadius).strokeBorder(Color.tkControl))
                    }
                    Toggle(String(localized: "All sensors"), isOn: $showAll)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 28)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if showAll {
                        ForEach(rawGroups, id: \.group) { entry in
                            Section {
                                ForEach(entry.rows) { SensorRow(context: context, descriptor: $0) }
                            } header: {
                                SensorColumnsHeader(title: entry.group.title)
                            }
                        }
                    } else {
                        Section {
                            ForEach(curatedRows) { SensorRow(context: context, descriptor: $0) }
                        } header: {
                            SensorColumnsHeader(title: String(localized: "Temperature"))
                        }
                        if !context.store.fans.current.isEmpty {
                            SectionLabel("Fans").padding(.top, 22)
                            FanRows(model: context.store.fans)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        .sampling(showAll ? [.temperatureFull, .electrical, .fans] : [.temperatureFull, .fans], every: 2, engine: context.engine)
    }
}

private struct SensorColumnsHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("Min").frame(width: 56, alignment: .trailing)
            Text("Avg").frame(width: 56, alignment: .trailing)
            Text("Max").frame(width: 56, alignment: .trailing)
            Text("Now").frame(width: 64, alignment: .trailing)
            Spacer().frame(width: 28)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.tkSecondary)
        .frame(height: 34)
        .background(Color.tkBackground)
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
        VStack(spacing: 0) {
            Hairline()
            HStack {
                Text(descriptor.name).lineLimit(1)
                Spacer(minLength: 12)
                Group {
                    Text(text(stats?.minimum)).frame(width: 56, alignment: .trailing)
                    Text(text(stats?.average)).frame(width: 56, alignment: .trailing)
                    Text(text(stats?.maximum)).frame(width: 56, alignment: .trailing)
                }
                .foregroundStyle(Color.tkSecondary)
                Text(isStale ? String(localized: "Lost") : text(stats?.latest))
                    .frame(width: 64, alignment: .trailing)
                    .foregroundStyle(isStale ? Color.tkSecondary : Color.tkPrimary)
                pinButton.frame(width: 28, alignment: .trailing)
            }
            .monospacedDigit()
            .frame(height: 29)
        }
    }

    @ViewBuilder private var pinButton: some View {
        if descriptor.kind == .temperature {
            Button {
                context.settings.updateWidget(.temperature) { config in
                    config.pinnedSensor = isPinned ? nil : descriptor.id
                    if !isPinned { config.enabled = true }
                }
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(isPinned ? Color.tkPrimary : Color.tkTertiary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Show this sensor in the Temperature menu bar module"))
            .accessibilityLabel(isPinned ? String(localized: "Unpin \(descriptor.name)") : String(localized: "Pin \(descriptor.name) to the menu bar"))
        }
    }
}
