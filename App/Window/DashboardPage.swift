import Core
import SwiftUI

struct DashboardPage: View {
    let context: AppContext

    private var store: MonitorStore { context.store }

    private var sources: Set<SampleSource> {
        var result: Set<SampleSource> = [.cpu, .memory, .temperatureSummary]
        if store.availability.hasGPU { result.insert(.gpu) }
        if store.availability.hasFans { result.insert(.fans) }
        if store.availability.hasBattery { result.formUnion([.battery, .power]) }
        return result
    }

    var body: some View {
        PageScroll {
            DashboardHeader(context: context)
            HStack(alignment: .top, spacing: 20) {
                CPUBlock(model: store.cpu)
                if store.availability.hasGPU { GPUBlock(model: store.gpu) }
                MemoryBlock(model: store.memory)
                if store.availability.hasBattery { PowerBlock(model: store.battery) }
            }
            .padding(.vertical, 20)
            Hairline()
            HStack(alignment: .top, spacing: 40) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("Temperature")
                    TemperatureRows(context: context)
                    if store.availability.hasFans {
                        SectionLabel("Fans").padding(.top, 22)
                        FanRows(model: store.fans)
                    }
                }
                .frame(maxWidth: .infinity)
                if store.availability.hasBattery {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionLabel("Battery")
                        BatterySummary(model: store.battery, limit: context.control.nativeChargeLimit)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 20)
        }
        .sampling(sources, engine: store.engine)
    }
}

private struct DashboardHeader: View {
    let context: AppContext

    var body: some View {
        let status = SystemStatus.line(store: context.store, unit: context.unit)
        PageHeader(title: WindowSection.dashboard.title, detail: context.control.statusLine(base: status.text), detailLevel: status.level) {
            RestoreButton(control: context.control)
        }
    }
}

private struct MetricBlock: View {
    let title: String
    let value: String
    let unit: String
    let detail: String
    let history: History
    var maximum: Float? = 100
    var alt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(Color.tkSecondary)
            BigNumber(value: value, unit: unit)
            Text(detail).font(.system(size: 12)).foregroundStyle(Color.tkSecondary).lineLimit(1)
            Sparkline(history: history, maximum: maximum).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(alt)
    }
}

private func wholePercent(_ fraction: Double?) -> String {
    fraction.map { "\(Int(($0 * 100).rounded()))" } ?? "–"
}

private struct CPUBlock: View {
    let model: CPUModel

    var body: some View {
        let current = model.current
        MetricBlock(
            title: String(localized: "CPU"),
            value: wholePercent(current?.usage),
            unit: "%",
            detail: current.map { String(localized: "\(Int(($0.system * 100).rounded())) system · \(Int(($0.user * 100).rounded())) user") } ?? " ",
            history: model.history,
            alt: String(localized: "CPU load \(wholePercent(current?.usage)) percent")
        )
    }
}

private struct GPUBlock: View {
    let model: GPUModel

    var body: some View {
        let current = model.current
        MetricBlock(
            title: String(localized: "GPU"),
            value: wholePercent(current?.device),
            unit: "%",
            detail: current?.renderer.map { String(localized: "Renderer \(Int(($0 * 100).rounded()))%") } ?? " ",
            history: model.history,
            alt: String(localized: "GPU load \(wholePercent(current?.device)) percent")
        )
    }
}

private struct MemoryBlock: View {
    let model: MemoryModel

    var body: some View {
        let current = model.current
        MetricBlock(
            title: String(localized: "Memory"),
            value: wholePercent(current?.usage),
            unit: "%",
            detail: current.map { String(localized: "\(Format.gigabytes($0.used)) of \(Format.gigabytes($0.total)) GB · \($0.pressure.title)") } ?? " ",
            history: model.history,
            alt: String(localized: "Memory use \(wholePercent(current?.usage)) percent")
        )
    }
}

private struct PowerBlock: View {
    let model: BatteryModel

    var body: some View {
        let watts = model.flow?.systemWatts
        MetricBlock(
            title: String(localized: "Power"),
            value: watts.map { String(format: "%.1f", $0) } ?? "–",
            unit: "W",
            detail: String(localized: "System load"),
            history: model.powerHistory,
            maximum: nil,
            alt: String(localized: "System power \(Format.watts(watts))")
        )
    }
}

struct TemperatureRows: View {
    let context: AppContext

    var body: some View {
        let summary = context.store.sensors.summary
        let rows: [(String, Double?)] = [
            (String(localized: "CPU hottest"), summary?.cpuHottest),
            (String(localized: "GPU"), summary?.gpu),
            (String(localized: "SSD"), summary?.ssd),
            (String(localized: "Battery"), summary?.battery)
        ]
        ForEach(rows.filter { $0.1 != nil }, id: \.0) { row in
            TemperatureRow(title: row.0, celsius: row.1 ?? 0, unit: context.unit)
        }
    }
}

private struct TemperatureRow: View {
    let title: String
    let celsius: Double
    let unit: TemperatureUnit

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 12) {
                Text(title).frame(width: 96, alignment: .leading)
                MeterBar(fraction: celsius / 100, color: celsius >= SystemStatus.hotCelsius ? .tkCritical : nil)
                Text(Format.temperature(celsius, unit: unit))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .frame(height: Tokens.Size.windowRow - 1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct FanRows: View {
    let model: FansModel
    var height = Tokens.Size.windowRow

    var body: some View {
        ForEach(model.current, id: \.index) { fan in
            ValueRow(String(localized: "Fan \(fan.index + 1)"), value: Format.fanSpeed(fan.actualRPM), height: height)
        }
    }
}

struct BatterySummary: View {
    let model: BatteryModel
    var limit: Int?

    var body: some View {
        if let battery = model.current {
            VStack(alignment: .leading, spacing: 0) {
                Hairline()
                HStack(alignment: .firstTextBaseline) {
                    BigNumber(value: "\(battery.percent)", unit: "%")
                    Spacer()
                    Text(BatteryText.detail(battery, limit: limit, flow: model.flow)).foregroundStyle(Color.tkSecondary)
                }
                .padding(.top, 14)
                MeterBar(fraction: Double(battery.percent) / 100, height: 6, marker: limit.map { Double($0) / 100 })
                    .padding(.top, 14)
                    .padding(.bottom, 18)
                PowerFlowRows(flow: model.flow ?? battery.flow)
                AccessoryRows(model: model)
                if let health = battery.health {
                    ValueRow(String(localized: "Capacity vs design"), value: Format.percent(health), secondary: true)
                }
                if let cycles = battery.cycleCount {
                    ValueRow(String(localized: "Cycles"), value: "\(cycles)", secondary: true)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}

enum BatteryText {
    static func detail(_ battery: BatterySnapshot, limit: Int? = nil, flow: PowerFlow? = nil) -> String {
        if battery.state == .charging, let limit, limit < 100, let minutes = LivePowerMath.minutesToLimit(
            percent: battery.percent, limit: limit, fullCapacityMilliampHours: battery.fullChargeCapacity,
            volts: battery.voltage, batteryWatts: flow?.chargingWatts
        ) {
            return String(localized: "About \(Format.duration(minutes: minutes)) to \(limit)%")
        }
        switch battery.state {
        case .charging:
            return battery.minutesToFull.map { String(localized: "Charging · \(Format.duration(minutes: $0)) to full") } ?? battery.state.title
        case .discharging:
            return battery.minutesToEmpty.map { String(localized: "\(Format.duration(minutes: $0)) remaining") } ?? battery.state.title
        case .notCharging:
            return battery.fullyCharged ? String(localized: "Fully charged") : battery.state.title
        }
    }
}

/// Devices the Mac is powering, each with its live draw. They are part of system load, so the Mac's own share is shown too.
struct AccessoryRows: View {
    let model: BatteryModel
    var height = Tokens.Size.windowRow

    var body: some View {
        if !model.accessories.isEmpty {
            ForEach(model.accessories) { accessory in
                ValueRow(accessory.name.map { String(localized: "\($0), port \(accessory.port)") } ?? String(localized: "Accessory, port \(accessory.port)"), value: Format.watts(accessory.watts), height: height)
            }
            if let mac = model.macWatts {
                ValueRow(String(localized: "Mac itself"), value: Format.watts(mac), secondary: true, height: height)
            }
        }
    }
}

struct PowerFlowRows: View {
    let flow: PowerFlow
    var height = Tokens.Size.windowRow

    var body: some View {
        switch flow {
        case let .onBattery(system):
            ValueRow(String(localized: "From battery"), value: Format.watts(system), height: height)
        case let .adapterCharging(adapter, system, battery):
            ValueRow(String(localized: "Adapter in"), value: Format.watts(adapter), height: height)
            ValueRow(String(localized: "To system"), value: Format.watts(system), height: height)
            ValueRow(String(localized: "To battery"), value: Format.watts(battery), height: height)
        case let .adapterOnly(adapter, system):
            ValueRow(String(localized: "Adapter in"), value: Format.watts(adapter), height: height)
            ValueRow(String(localized: "To system"), value: Format.watts(system), height: height)
        case let .batteryAssist(adapter, system, battery):
            ValueRow(String(localized: "Adapter in"), value: Format.watts(adapter), height: height)
            ValueRow(String(localized: "Battery assists"), value: Format.watts(battery), height: height)
            ValueRow(String(localized: "To system"), value: Format.watts(system), height: height)
        case .inconsistent:
            ValueRow(String(localized: "Power flow"), value: String(localized: "N/A"), secondary: true, height: height)
        }
    }
}
