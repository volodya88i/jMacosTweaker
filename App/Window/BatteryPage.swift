import Core
import SwiftUI

struct BatteryPage: View {
    let context: AppContext

    var body: some View {
        let model = context.store.battery
        PageScroll {
            if let battery = model.current {
                Card {
                    BatteryHero(model: model, battery: battery, limit: context.control.nativeChargeLimit)
                }
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 14) {
                        ChargeLimitSection(context: context, battery: battery)
                        Card {
                            CardHeader(symbol: "bolt", title: String(localized: "Power")) {
                                if let watts = model.flow?.systemWatts { Text("System \(Format.watts(watts))") }
                            }
                            PowerFlowView(flow: model.flow ?? battery.flow)
                            AccessoryRows(model: model)
                            Sparkline(history: model.powerHistory, maximum: nil, height: 44)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 14) {
                        Card {
                            CardHeader(symbol: "heart", title: String(localized: "Condition"))
                            InfoRows(items: details(battery))
                        }
                        if let adapter = battery.adapter {
                            Card {
                                CardHeader(symbol: "powerplug", title: String(localized: "Power Adapter"))
                                InfoRows(items: adapterRows(adapter))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView(String(localized: "Reading the battery…"), systemImage: "battery.75percent")
                    .frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .navigationSubtitle(model.current.map { BatteryText.detail($0, limit: context.control.nativeChargeLimit, flow: model.flow) } ?? "")
        .sampling([.battery, .power], engine: context.engine)
        .task { await context.control.refresh() }
    }

    private func details(_ battery: BatterySnapshot) -> [InfoRows.Item] {
        let healthColor: Color? = battery.health.map { $0 < 0.8 ? .orange : .secondary }
        return [
            .init(title: String(localized: "State"), value: battery.state.title),
            .init(title: String(localized: "Capacity vs design"), value: battery.health.map(Format.percent) ?? String(localized: "N/A"), color: healthColor),
            .init(title: String(localized: "Cycles"), value: battery.cycleCount.map { "\($0)" } ?? String(localized: "N/A")),
            .init(title: String(localized: "Temperature"), value: Format.temperature(battery.temperature, unit: context.unit)),
            .init(title: String(localized: "Voltage"), value: battery.voltage.map { String(format: "%.2f V", $0) } ?? String(localized: "N/A")),
            .init(title: String(localized: "Current"), value: battery.amperage.map { String(format: "%.2f A", $0) } ?? String(localized: "N/A"))
        ]
    }

    private func adapterRows(_ adapter: AdapterInfo) -> [InfoRows.Item] {
        var rows: [InfoRows.Item] = []
        if let name = adapter.name { rows.append(.init(title: String(localized: "Name"), value: name)) }
        if let watts = adapter.ratedWatts { rows.append(.init(title: String(localized: "Rated"), value: String(format: "%.0f W", watts))) }
        if let volts = adapter.voltage { rows.append(.init(title: String(localized: "Voltage"), value: String(format: "%.1f V", volts))) }
        return rows
    }
}
