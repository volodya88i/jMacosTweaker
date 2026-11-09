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
    var presets: [FanPreset] = FanPreset.allCases
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
        case .constant: "lock"
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
        case .constant: String(localized: "One fixed speed")
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
