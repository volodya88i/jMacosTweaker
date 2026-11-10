import Core
import SwiftUI

// Cards shared by the main window and the menu bar panels, so both always say the same thing.

/// One metric: icon and title, a big number, one line of detail, and recent history.
struct MetricTile: View {
    let symbol: String
    let title: String
    let value: String
    var unit = "%"
    let detail: String
    let history: History
    var maximum: Float? = 100
    var level = ValueLevel.normal
    let accessibility: String

    var body: some View {
        Card {
            CardHeader(symbol: symbol, title: title)
            VStack(alignment: .leading, spacing: 2) {
                BigValue(value: value, unit: unit, color: LevelColor.color(level, fallback: .primary))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Sparkline(history: history, maximum: maximum, tint: level == .normal ? nil : LevelColor.color(level, fallback: .accentColor), height: 34)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }
}

func wholePercent(_ fraction: Double?) -> String {
    fraction.map { "\(Int(($0 * 100).rounded()))" } ?? "–"
}

// MARK: Temperature

/// The four temperatures that matter, each with a bar that turns orange and red as it climbs.
struct TemperatureRows: View {
    let context: AppContext

    var body: some View {
        let summary = context.store.sensors.summary
        let rows = TemperatureArea.allCases.compactMap { area in summary.flatMap(area.value).map { (area, $0) } }
        VStack(spacing: 9) {
            ForEach(rows, id: \.0) { area, celsius in
                let level = LevelColor.temperatureLevel(celsius)
                HStack(spacing: 10) {
                    Text(area == .cpu ? String(localized: "CPU hottest") : area.title)
                        .frame(width: 92, alignment: .leading)
                        .lineLimit(1)
                    // State colors, not the graph color: a bar that means "fine" should not look like an alarm.
                    CapsuleBar(fraction: (celsius - 20) / 85, tint: LevelColor.color(level, fallback: .green))
                    Text(Format.temperature(celsius, unit: context.unit))
                        .monospacedDigit()
                        .foregroundStyle(LevelColor.color(level, fallback: .primary))
                        .frame(width: 42, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
            if rows.isEmpty {
                Text("Waiting for sensors…").foregroundStyle(.secondary)
            }
        }
    }
}

struct TemperatureCard: View {
    let context: AppContext

    var body: some View {
        Card {
            CardHeader(symbol: "thermometer.medium", title: String(localized: "Temperature")) {
                if let hottest = context.store.sensors.summary?.hottest {
                    Text("Hottest \(Format.temperature(hottest, unit: context.unit))")
                }
            }
            TemperatureRows(context: context)
        }
    }
}

/// Recent temperatures of each area in one chart, one system color per area. The legend repeats each color with the
/// current value, so a reading never depends on telling colors apart alone.
struct TemperatureChart: View {
    let context: AppContext
    var height: CGFloat = 70

    static func color(_ area: TemperatureArea) -> Color {
        switch area {
        case .cpu: .orange
        case .gpu: .purple
        case .ssd: .teal
        case .battery: .green
        }
    }

    var body: some View {
        let sensors = context.store.sensors
        let areas = TemperatureArea.allCases.filter { sensors.areaHistory[$0] != nil }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ForEach(areas) { area in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Self.color(area))
                            .frame(width: 7, height: 7)
                        Text(area.title).foregroundStyle(.secondary)
                        Text(Format.temperature(sensors.summary.flatMap(area.value), unit: context.unit))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .lineLimit(1)
                }
            }
            Canvas { graphics, size in
                var low = Float.infinity, high = -Float.infinity
                for area in areas {
                    sensors.areaHistory[area]?.forEach { value in
                        guard !value.isNaN else { return }
                        low = min(low, value)
                        high = max(high, value)
                    }
                }
                guard low.isFinite, high.isFinite else { return }
                let bottom = floor(low / 10) * 10, top = max(ceil(high / 10) * 10, bottom + 10)
                for line in stride(from: bottom, through: top, by: 10) {
                    let y = size.height - CGFloat((line - bottom) / (top - bottom)) * size.height
                    var grid = Path()
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                    graphics.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
                }
                for area in areas {
                    guard let history = sensors.areaHistory[area], history.count > 1 else { continue }
                    let step = size.width / CGFloat(history.count - 1)
                    let offset = 0
                    var path = Path()
                    var drawing = false
                    var index = 0
                    history.forEach { value in
                        defer { index += 1 }
                        guard !value.isNaN else {
                            drawing = false
                            return
                        }
                        let point = CGPoint(x: CGFloat(offset + index) * step, y: size.height - CGFloat((value - bottom) / (top - bottom)) * size.height)
                        if drawing { path.addLine(to: point) } else { path.move(to: point) }
                        drawing = true
                    }
                    graphics.stroke(path, with: .color(Self.color(area)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Temperature history"))
    }
}

// MARK: Fans

/// One fan, the way a fan utility shows it: mode, big speed, a bar against the maximum, and the hardware limits.
struct FanTile: View {
    let fan: FanSnapshot
    let controlled: Bool
    var target: Double?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(spacing: 6) {
                // Not animated: a spinning icon would redraw constantly, and this app must stay light on the Mac.
                Image(systemName: "fan")
                    .foregroundStyle(.secondary)
                Text("Fan \(fan.index + 1)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if controlled {
                    StatusBadge(text: String(localized: "Manual"), color: .accentColor)
                } else {
                    StatusBadge(text: String(localized: "Auto"))
                }
            }
            if fan.actualRPM == 0 {
                BigValue(value: String(localized: "Stopped"), size: compact ? 24 : 28, color: .secondary)
            } else {
                BigValue(value: Format.rpm(fan.actualRPM), unit: "rpm", size: compact ? 24 : 28)
            }
            CapsuleBar(fraction: fan.maximumRPM > 0 ? fan.actualRPM / fan.maximumRPM : 0)
            HStack {
                Text("Min \(Format.rpm(fan.minimumRPM))")
                Spacer()
                if let target, controlled {
                    Text("Target \(Format.rpm(target))")
                    Spacer()
                }
                Text("Max \(Format.rpm(fan.maximumRPM))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// All fans side by side.
struct FansGrid: View {
    let context: AppContext
    var compact = false

    var body: some View {
        let status = context.control.helper.status
        let fans = context.store.fans.current
        if fans.isEmpty {
            Text("Waiting for fan readings…").foregroundStyle(.secondary)
        } else {
            Grid(horizontalSpacing: compact ? 18 : 24, verticalSpacing: 14) {
                ForEach(Array(stride(from: 0, to: fans.count, by: 2)), id: \.self) { start in
                    GridRow {
                        ForEach(fans[start..<min(start + 2, fans.count)], id: \.index) { fan in
                            FanTile(
                                fan: fan,
                                controlled: status?.fansUnderControl.contains(fan.index) == true,
                                target: status?.targets[fan.index],
                                compact: compact
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: Battery

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
            if battery.fullyCharged { return String(localized: "Fully charged") }
            if let limit, limit < 100, battery.percent >= limit - 1 { return String(localized: "Held at the \(limit)% limit") }
            return battery.state.title
        }
    }

    static func symbol(_ battery: BatterySnapshot) -> String {
        if battery.state == .charging { return "battery.100percent.bolt" }
        switch battery.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func level(_ battery: BatterySnapshot) -> ValueLevel {
        guard battery.state == .discharging else { return .normal }
        if battery.percent <= SystemStatus.lowBatteryPercent { return .critical }
        if battery.percent <= 20 { return .warning }
        return .normal
    }
}

/// Charge, state and the limit marker.
struct BatteryHero: View {
    let model: BatteryModel
    let battery: BatterySnapshot
    var limit: Int?
    var compact = false

    var body: some View {
        let level = BatteryText.level(battery)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: BatteryText.symbol(battery))
                    .font(.system(size: compact ? 26 : 34))
                    .foregroundStyle(level == .normal ? (battery.state == .charging ? Color.green : .primary) : LevelColor.color(level, fallback: .primary))
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    BigValue(value: "\(battery.percent)", unit: "%", size: compact ? 26 : 34)
                    Text(BatteryText.detail(battery, limit: limit, flow: model.flow))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            CapsuleBar(
                fraction: Double(battery.percent) / 100,
                tint: LevelColor.color(level, fallback: .green),
                height: 8,
                marker: limit.flatMap { $0 < 100 ? Double($0) / 100 : nil }
            )
        }
        .accessibilityElement(children: .combine)
    }
}

/// Where the power goes: adapter, Mac and battery, with watts on each path.
struct PowerFlowView: View {
    let flow: PowerFlow

    var body: some View {
        switch flow {
        case let .onBattery(system):
            HStack(spacing: 0) {
                node("battery.75percent", String(localized: "Battery"))
                arrow(Format.watts(system))
                node("laptopcomputer", String(localized: "Mac"))
            }
        case let .adapterCharging(adapter, system, battery):
            HStack(spacing: 0) {
                node("powerplug.fill", String(localized: "Adapter"), detail: Format.watts(adapter))
                arrow(Format.watts(system))
                node("laptopcomputer", String(localized: "Mac"))
                arrow(Format.watts(battery))
                node("battery.100percent.bolt", String(localized: "Battery"), color: .green)
            }
        case let .adapterOnly(adapter, system):
            HStack(spacing: 0) {
                node("powerplug.fill", String(localized: "Adapter"), detail: Format.watts(adapter))
                arrow(Format.watts(system))
                node("laptopcomputer", String(localized: "Mac"))
                arrow(String(localized: "0 W"), dim: true)
                node("battery.100percent", String(localized: "Battery"), dim: true)
            }
        case let .batteryAssist(adapter, system, battery):
            HStack(spacing: 0) {
                node("powerplug.fill", String(localized: "Adapter"), detail: Format.watts(adapter))
                arrow(Format.watts(adapter))
                node("laptopcomputer", String(localized: "Mac"), detail: Format.watts(system))
                arrow(Format.watts(battery), reversed: true, color: .orange)
                node("battery.50percent", String(localized: "Battery"), color: .orange)
            }
        case .inconsistent:
            InlineNotice(text: String(localized: "Power figures do not add up right now, so none are shown. This is normal for about 30 seconds after plugging in."))
        }
    }

    private func node(_ symbol: String, _ title: String, detail: String? = nil, color: Color = .primary, dim: Bool = false) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(height: 24)
            Text(title).font(.caption)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
        }
        .opacity(dim ? 0.45 : 1)
        .frame(minWidth: 58)
    }

    private func arrow(_ watts: String, reversed: Bool = false, dim: Bool = false, color: Color? = nil) -> some View {
        VStack(spacing: 2) {
            Text(watts).font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(color ?? .primary)
            Image(systemName: reversed ? "arrow.left" : "arrow.right")
                .font(.caption)
                .foregroundStyle(color ?? .secondary)
        }
        .opacity(dim ? 0.45 : 1)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 14)
    }
}

/// Devices the Mac is powering, each with its live draw. They are part of system load, so the Mac's own share is shown too.
struct AccessoryRows: View {
    let model: BatteryModel

    var body: some View {
        if !model.accessories.isEmpty {
            InfoRows(items: model.accessories.map { accessory in
                InfoRows.Item(
                    title: accessory.name.map { String(localized: "\($0), port \(accessory.port)") } ?? String(localized: "Accessory, port \(accessory.port)"),
                    value: Format.watts(accessory.watts)
                )
            } + (model.macWatts.map { [InfoRows.Item(title: String(localized: "Mac itself"), value: Format.watts($0))] } ?? []))
        }
    }
}

struct BatteryCard: View {
    let context: AppContext

    var body: some View {
        let model = context.store.battery
        if let battery = model.current {
            Card {
                CardHeader(symbol: "battery.75percent", title: String(localized: "Battery")) {
                    if let health = battery.health { Text("Capacity \(Format.percent(health))") }
                }
                BatteryHero(model: model, battery: battery, limit: context.control.nativeChargeLimit)
                Divider()
                PowerFlowView(flow: model.flow ?? battery.flow)
                AccessoryRows(model: model)
            }
        }
    }
}
