import Core
import SwiftUI

struct BatteryPage: View {
    let context: AppContext

    var body: some View {
        PageScroll {
            let model = context.store.battery
            PageHeader(
                title: WindowSection.battery.title,
                detail: model.current.map { BatteryText.detail($0, limit: context.control.nativeChargeLimit, flow: model.flow) }
            )
            if let battery = model.current {
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 0) {
                        BigNumber(value: "\(battery.percent)", unit: "%").padding(.vertical, 14)
                        MeterBar(
                            fraction: Double(battery.percent) / 100, height: 6,
                            marker: context.control.nativeChargeLimit.map { Double($0) / 100 }
                        )
                        .padding(.bottom, 18)
                        ChargeLimitSection(context: context, battery: battery).padding(.bottom, 22)
                        SectionLabel("Power")
                        PowerFlowRows(flow: model.flow ?? battery.flow)
                        AccessoryRows(model: model)
                        Sparkline(history: model.powerHistory, maximum: nil).padding(.top, 14)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 0) {
                        SectionLabel("Details").padding(.top, 20)
                        ValueRow(String(localized: "State"), value: battery.state.title)
                        ValueRow(String(localized: "Capacity vs design"), value: battery.health.map(Format.percent) ?? String(localized: "N/A"))
                        ValueRow(String(localized: "Cycles"), value: battery.cycleCount.map { "\($0)" } ?? String(localized: "N/A"))
                        ValueRow(String(localized: "Temperature"), value: Format.temperature(battery.temperature, unit: context.unit))
                        ValueRow(String(localized: "Voltage"), value: battery.voltage.map { String(format: "%.2f V", $0) } ?? String(localized: "N/A"))
                        ValueRow(String(localized: "Current"), value: battery.amperage.map { String(format: "%.2f A", $0) } ?? String(localized: "N/A"))
                        if let adapter = battery.adapter {
                            SectionLabel("Adapter").padding(.top, 22)
                            if let name = adapter.name { ValueRow(String(localized: "Name"), value: name) }
                            if let watts = adapter.ratedWatts { ValueRow(String(localized: "Rated"), value: String(format: "%.0f W", watts)) }
                            if let volts = adapter.voltage { ValueRow(String(localized: "Voltage"), value: String(format: "%.1f V", volts)) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .sampling([.battery, .power], engine: context.engine)
        .task { await context.control.refresh() }
    }
}
