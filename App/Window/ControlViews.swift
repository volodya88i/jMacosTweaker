import AppKit
import Core
import Shared
import SwiftUI

/// Always reachable. Disabled only when there is no helper to restore anything.
struct RestoreButton: View {
    let control: ControlModel

    var body: some View {
        Button {
            control.restoreDefaults()
        } label: {
            Label(String(localized: "Restore System Defaults"), systemImage: "arrow.uturn.backward.circle")
        }
        .disabled(control.helper.state != .running)
        .help(String(localized: "Returns fans and charging to system control"))
    }
}

struct FanPresetPicker: View {
    let control: ControlModel
    var presets: [FanPreset] = FanPreset.offered
    var fan: Int?

    var body: some View {
        Picker(String(localized: "Fan mode"), selection: Binding(
            get: {
                let settings = control.settingsSnapshot
                if let fan { return settings.perFan[fan] ?? .system }
                return settings.preset
            },
            set: { control.select(preset: $0, fan: fan) }
        )) {
            ForEach(presets, id: \.self) { preset in
                Text(preset.title).tag(preset)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

extension FanPreset {
    var symbol: String {
        switch self {
        case .system: "arrow.triangle.2.circlepath"
        case .silent: "speaker.slash"
        case .balanced: "circle.lefthalf.filled"
        case .performance: "gauge.with.dots.needle.67percent"
        case .maximum: "bolt.fill"
        case .constant: "dial.medium"
        case .custom: "slider.horizontal.3"
        }
    }

    var caption: String {
        switch self {
        case .system: String(localized: "macOS decides")
        case .silent: String(localized: "Full speed at 90°")
        case .balanced: String(localized: "Full speed at 88°")
        case .performance: String(localized: "Full speed at 82°")
        case .maximum: String(localized: "Always 100%")
        case .constant: String(localized: "One speed, any temperature")
        case .custom: String(localized: "Your own curve")
        }
    }
}

struct NativeChargeLimitPicker: View {
    let control: ControlModel

    var body: some View {
        Picker(String(localized: "Charge limit"), selection: Binding(
            get: { control.nativeChargeLimit ?? 100 },
            set: { control.setNativeChargeLimit($0) }
        )) {
            ForEach(control.nativeChargeOptions, id: \.self) { value in
                Text("\(value)%").tag(value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// The charge limit card. On macOS with a built-in limit this is the same setting as System Settings. The helper's own
/// engine is shown only where it has been verified, which is nowhere yet.
struct ChargeLimitSection: View {
    let context: AppContext
    let battery: BatterySnapshot

    private var control: ControlModel { context.control }
    private var charge: ChargeRequest { context.settings.stored.charge }

    var body: some View {
        Card {
            CardHeader(symbol: "bolt.batteryblock", title: String(localized: "Charge Limit")) {
                if let limit = control.nativeChargeLimit, limit < 100 { Text("\(limit)%") }
            }
            if !control.nativeChargeOptions.isEmpty {
                NativeChargeLimitPicker(control: control)
                Text("Charging stops at this level and the Mac runs from the adapter without using the battery. This is the same setting as in System Settings, and macOS offers only these values.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = control.nativeChargeError {
                    InlineNotice(text: error, level: .warning)
                }
            } else if control.helper.status?.chargeCapability.isAvailable == true {
                if let reason = control.chargeBlockReason {
                    InlineNotice(text: reason)
                } else {
                    helperControls
                }
            } else if control.nativeChargeChecked {
                InlineNotice(text: String(localized: "This macOS has no built-in charge limit, and no verified way to set one on this Mac."))
            }
            if control.nativeChargeLimit == nil, battery.state == .notCharging, control.helper.status?.chargeAction != .inhibitCharging, !battery.fullyCharged {
                InlineNotice(text: String(localized: "macOS is holding charge right now. Optimized Battery Charging or a limit in System Settings works on its own and can stop charging below your limit."))
            }
            if let error = control.helper.lastError {
                InlineNotice(text: error, level: .warning)
            }
        }
    }

    @ViewBuilder private var helperControls: some View {
        Toggle(String(localized: "Limit charging"), isOn: Binding(
            get: { charge.enabled },
            set: { value in control.updateCharge { $0.enabled = value } }
        ))
        if charge.enabled {
            LabeledContent(String(localized: "Limit")) {
                HStack {
                    Slider(value: Binding(
                        get: { Double(charge.limit) },
                        set: { value in control.updateCharge { $0.limit = Int(value); $0.topUp = false } }
                    ), in: 50...100, step: 5)
                    Text("\(charge.limit)%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Stepper(value: Binding(get: { charge.sailing }, set: { value in control.updateCharge { $0.sailing = value } }), in: 1...20) {
                LabeledContent(String(localized: "Resume below limit by"), value: "\(charge.sailing)%")
            }
            Toggle(String(localized: "Pause when the battery is hot"), isOn: Binding(
                get: { charge.heatProtection },
                set: { value in control.updateCharge { $0.heatProtection = value } }
            ))
            if charge.heatProtection {
                Stepper(value: Binding(get: { Int(charge.heatLimit) }, set: { value in control.updateCharge { $0.heatLimit = Double(value) } }), in: 30...50) {
                    LabeledContent(String(localized: "Hot above"), value: "\(Int(charge.heatLimit)) °C")
                }
            }
            Button(charge.topUp ? String(localized: "Cancel Top Up") : String(localized: "Top Up to 100%")) {
                control.updateCharge { $0.topUp.toggle() }
            }
        }
    }
}

/// Helper state, the exact command to run, and how to undo it. The app never asks for a password.
struct HelperSection: View {
    let control: ControlModel
    @State private var showUninstall = false

    private var state: (text: String, color: Color) {
        switch control.helper.state {
        case .checking: (String(localized: "Checking"), .secondary)
        case .notInstalled: (String(localized: "Not installed"), .secondary)
        case .needsRepin: (String(localized: "Needs re-pin"), .orange)
        case .notInstalledCopy: (String(localized: "Open the installed copy"), .orange)
        case .outdated: (String(localized: "Outdated"), .orange)
        case .notResponding: (String(localized: "Not responding"), .red)
        case .running: (String(localized: "Running"), .green)
        }
    }

    var body: some View {
        Section {
            LabeledContent(String(localized: "Status")) {
                StatusBadge(text: state.text, color: state.color)
            }
            if let status = control.helper.status {
                LabeledContent(String(localized: "Protocol"), value: "\(status.protocolVersion)")
            }
            if control.helper.state != .running {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fan control needs a small root helper. Run this in Terminal. It copies the app to /Applications, installs the helper and pins this build. Run it again after every rebuild.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    CommandLineView(command: control.installCommand)
                    if Bundle.main.bundlePath.hasPrefix("/Volumes/") {
                        Text("Running from the disk image? Double-click Install jMacosTweaker.command next to the app instead. It does the same.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !control.idleConflictNames.isEmpty {
                InlineNotice(text: String(localized: "Also installed: \(control.idleConflictNames.joined(separator: ", ")). Not running now, but it could conflict if started."))
            }
            if control.helper.state == .running {
                LabeledContent(String(localized: "Uninstall")) {
                    Button(String(localized: "Restore Defaults and Prepare Uninstall…")) {
                        control.restoreDefaults()
                        showUninstall = true
                    }
                }
            }
            if showUninstall {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Defaults restored. To remove the helper, run this in Terminal:")
                        .foregroundStyle(.secondary)
                    CommandLineView(command: control.uninstallCommand)
                }
            }
        } header: {
            Text("Privileged Helper")
        } footer: {
            Text("Monitoring never needs the helper. Without it, fan control is read-only.")
                .foregroundStyle(.secondary)
        }
        .task { await control.refresh() }
    }
}

/// Pause Charging: sets the adapter aside so the Mac runs from its battery, until a time or a level. A backup for when
/// the macOS limit does not hold. The helper runs it, so it keeps going with the app closed.
struct ChargePauseCard: View {
    let context: AppContext
    var compact = false

    @State private var duration: TimeInterval? = 3600
    @State private var limitByLevel = true
    @State private var level = 50

    private var control: ControlModel { context.control }

    static let durations: [(TimeInterval?, String)] = [
        (1800, String(localized: "30 min")), (3600, String(localized: "1 hour")), (7200, String(localized: "2 hours")),
        (14400, String(localized: "4 hours")), (nil, String(localized: "No time limit"))
    ]

    var body: some View {
        Group {
            if compact { compactRow } else { fullCard }
        }
        // While a pause runs, its end is checked now and then, so the card notices when the helper ends it.
        .task(id: control.chargePause) {
            while control.chargePause != nil, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                await control.helper.refresh()
            }
        }
    }

    private var fullCard: some View {
        Card {
            CardHeader(symbol: "pause.circle", title: String(localized: "Pause Charging")) {
                if control.chargePause != nil { StatusBadge(text: String(localized: "Paused"), color: .orange) }
            }
            if let pause = control.chargePause {
                active(pause)
            } else if let reason = control.chargeBlockReason {
                InlineNotice(text: reason)
                if control.helper.state != .running, control.helper.state != .checking {
                    CommandLineView(command: control.installCommand)
                }
            } else {
                setup
            }
        }
    }

    /// One row for the menu bar popovers: state on the left, Pause or Resume on the right.
    private var compactRow: some View {
        let pause = control.chargePause
        let blocked = control.chargeBlockReason != nil
        return Card(padding: 12) {
            HStack(spacing: 10) {
                Image(systemName: pause == nil ? "bolt.batteryblock" : "pause.circle.fill")
                    .font(.title3)
                    .foregroundStyle(pause == nil ? Color.secondary : .orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pause == nil ? String(localized: "Charging") : String(localized: "Charging paused"))
                        .font(.subheadline.weight(.semibold))
                    Text(pause.map { String(localized: "On battery \(ControlModel.describe($0))") }
                         ?? (blocked
                             ? (control.helper.state == .running ? String(localized: "Pausing is not available on this Mac") : String(localized: "Pausing needs the helper"))
                             : String(localized: "Stop charging for a while")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 6)
                if pause != nil {
                    Button(String(localized: "Resume")) { control.resumeCharging() }
                        .glassProminentButton()
                } else if !blocked {
                    Menu(String(localized: "Pause")) {
                        Section(String(localized: "For")) {
                            ForEach(Self.durations.filter { $0.0 != nil }, id: \.1) { value, title in
                                Button(title) { control.pauseCharging(for: value, untilPercent: nil) }
                            }
                        }
                        Section(String(localized: "Until the battery is at")) {
                            ForEach([80, 70, 60, 50], id: \.self) { level in
                                Button("\(level)%") { control.pauseCharging(for: nil, untilPercent: level) }
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            .controlSize(.small)
        }
    }

    private func active(_ pause: ChargePause) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Running from the battery \(ControlModel.describe(pause)).")
                .fixedSize(horizontal: false, vertical: true)
            Button {
                control.resumeCharging()
            } label: {
                Label(String(localized: "Resume Charging"), systemImage: "bolt.fill")
            }
            .glassProminentButton()
            .controlSize(compact ? .small : .regular)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(String(localized: "For"), selection: $duration) {
                ForEach(Self.durations, id: \.1) { value, title in Text(title).tag(value) }
            }
            .fixedSize()
            HStack {
                Toggle(String(localized: "Or until the battery is at"), isOn: $limitByLevel)
                Stepper(value: $level, in: ChargeStateMachine.pauseLevelRange, step: 5) {
                    Text("\(level)%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                .disabled(!limitByLevel)
            }
            Button {
                control.pauseCharging(for: duration, untilPercent: limitByLevel ? level : nil)
            } label: {
                Label(String(localized: "Pause Charging"), systemImage: "pause.fill")
            }
            .glassProminentButton()
            .disabled(duration == nil && !limitByLevel)
            Text("The Mac runs from its battery even on the adapter, so the level goes down. Charging comes back at the time or level you chose, at 20% at the latest, before the Mac sleeps, after a day at most, and when you press Resume. Then the macOS limit applies again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
