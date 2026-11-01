import AppKit
import Core
import Shared
import SwiftUI

/// Explains why something is unavailable. Always says what to do next.
struct ControlNotice: View {
    let text: String
    var level = ValueLevel.normal

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: level == .normal ? "info.circle" : "exclamationmark.triangle")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .foregroundStyle(LevelColor.color(level, fallback: .tkSecondary))
    }
}

/// Always reachable. Disabled only when there is nothing to restore.
struct RestoreButton: View {
    let control: ControlModel
    var short = false

    var body: some View {
        Button(short ? String(localized: "Restore defaults") : String(localized: "Restore system defaults")) {
            control.restoreDefaults()
        }
        .buttonStyle(InstrumentButtonStyle())
        .disabled(control.helper.state != .running)
        .help(String(localized: "Returns fans and charging to system control"))
    }
}

struct FanPresetPicker: View {
    let control: ControlModel
    var presets: [FanPreset] = FanPreset.allCases
    var fan: Int?

    private var selection: Binding<FanPreset> {
        Binding(
            get: {
                let settings = control.settingsSnapshot
                if let fan { return settings.perFan[fan] ?? .system }
                return settings.preset
            },
            set: { control.select(preset: $0, fan: fan) }
        )
    }

    var body: some View {
        SegmentedPicker(options: presets.map { ($0, $0.title) }, selection: selection, label: String(localized: "Fan preset"))
    }
}

/// Shows helper state, the exact command to run, and how to undo it. The app never asks for a password.
struct HelperSection: View {
    let control: ControlModel
    @State private var showUninstall = false

    private var stateText: String {
        switch control.helper.state {
        case .checking: String(localized: "Checking")
        case .notInstalled: String(localized: "Not installed")
        case .needsRepin: String(localized: "Needs re-pin after a rebuild")
        case .notInstalledCopy: String(localized: "Installed for the copy in /Applications")
        case .outdated: String(localized: "Outdated")
        case .notResponding: String(localized: "Not responding")
        case .running: String(localized: "Running")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ValueRow(String(localized: "State"), value: stateText)
            if control.helper.state != .running {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fan control needs a small root helper. Run this in Terminal. It copies the app to /Applications, installs the helper and pins this build. Run it again after every rebuild.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.tkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    CommandLineView(command: control.installCommand)
                }
                .padding(.vertical, 10)
            }
            if !control.idleConflictNames.isEmpty {
                ControlNotice(text: String(localized: "Also installed: \(control.idleConflictNames.joined(separator: ", ")). Not running now, but it could conflict if started."))
                    .padding(.vertical, 8)
            }
            if control.helper.state == .running {
                HStack {
                    Spacer()
                    Button(String(localized: "Restore defaults and prepare uninstall")) {
                        control.restoreDefaults()
                        showUninstall = true
                    }
                    .buttonStyle(InstrumentButtonStyle())
                }
                .padding(.vertical, 8)
            }
            if showUninstall {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Defaults restored. To remove the helper, run this in Terminal:")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.tkSecondary)
                    CommandLineView(command: control.uninstallCommand)
                }
                .padding(.vertical, 8)
            }
        }
        .task { await control.refresh() }
    }
}

struct CommandLineView: View {
    let command: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(String(localized: "Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .buttonStyle(InstrumentButtonStyle())
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Size.controlRadius).strokeBorder(Color.tkControl))
    }
}

struct NativeChargeLimitPicker: View {
    let control: ControlModel

    var body: some View {
        SegmentedPicker(
            options: control.nativeChargeOptions.map { ($0, "\($0)%") },
            selection: Binding(
                get: { control.nativeChargeLimit ?? 100 },
                set: { control.setNativeChargeLimit($0) }
            ),
            label: String(localized: "Charge limit")
        )
    }
}

struct ChargeLimitSlider: View {
    let control: ControlModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Charge limit")
                Spacer()
                Text(control.settingsChargeSnapshot.enabled ? "\(control.settingsChargeSnapshot.limit)%" : String(localized: "Off")).monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(control.settingsChargeSnapshot.limit) },
                    set: { value in
                        control.updateCharge {
                            $0.limit = Int(value)
                            $0.enabled = true
                            $0.topUp = false
                        }
                    }
                ),
                in: 50...100,
                step: 5
            )
            .controlSize(.small)
            .accessibilityLabel(String(localized: "Charge limit"))
        }
    }
}

struct ChargeLimitSection: View {
    let context: AppContext
    let battery: BatterySnapshot

    private var control: ControlModel { context.control }
    private var charge: ChargeRequest { context.settings.stored.charge }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Charge limit")
            if control.nativeChargeOptions.isEmpty {
                if control.helper.status?.chargeCapability.isAvailable != true {
                    // The helper cannot change this, so it is not offered as a fix.
                    if control.nativeChargeChecked {
                        Hairline()
                        ControlNotice(text: String(localized: "This macOS has no built-in charge limit, and no verified way to set one on this Mac."))
                            .padding(.vertical, 10)
                    }
                } else if let reason = control.chargeBlockReason {
                    Hairline()
                    ControlNotice(text: reason).padding(.vertical, 10)
                } else {
                    Hairline()
                    Toggle(String(localized: "Limit charging"), isOn: Binding(
                        get: { charge.enabled },
                        set: { value in control.updateCharge { $0.enabled = value } }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .frame(height: 33)
                    if charge.enabled {
                        ChargeLimitSlider(control: control).padding(.vertical, 8)
                        Hairline()
                        stepperRow(String(localized: "Resume below limit by"), value: charge.sailing, range: 1...20, unit: "%") { value in
                            control.updateCharge { $0.sailing = value }
                        }
                        Hairline()
                        Toggle(String(localized: "Pause when battery is hot"), isOn: Binding(
                            get: { charge.heatProtection },
                            set: { value in control.updateCharge { $0.heatProtection = value } }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .frame(height: 33)
                        if charge.heatProtection {
                            Hairline()
                            stepperRow(String(localized: "Hot above"), value: Int(charge.heatLimit), range: 30...50, unit: "°C") { value in
                                control.updateCharge { $0.heatLimit = Double(value) }
                            }
                        }
                        Hairline()
                        HStack {
                            Button(charge.topUp ? String(localized: "Cancel top up") : String(localized: "Top up to 100%")) {
                                control.updateCharge { $0.topUp.toggle() }
                            }
                            .buttonStyle(InstrumentButtonStyle())
                            Spacer()
                        }
                        .padding(.vertical, 10)
                    }
                }
            } else {
                Hairline()
                NativeChargeLimitPicker(control: control).padding(.top, 10)
                Text("Charging stops at this level and the Mac runs from the adapter, without using the battery. This is the same setting as in System Settings. macOS offers only these values.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.tkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 10)
                if let error = control.nativeChargeError {
                    ControlNotice(text: error, level: .warning).padding(.bottom, 8)
                }
            }
            if control.nativeChargeLimit == nil, battery.state == .notCharging, !(control.helper.status?.chargeAction == .inhibitCharging), !battery.fullyCharged {
                ControlNotice(text: String(localized: "macOS is holding charge right now. Optimized Battery Charging or a limit in System Settings works on its own and can stop charging below your limit."))
                    .padding(.top, 8)
            }
            if let error = control.helper.lastError {
                ControlNotice(text: error, level: .warning).padding(.top, 8)
            }
        }
    }

    private func stepperRow(_ title: String, value: Int, range: ClosedRange<Int>, unit: String, onChange: @escaping @MainActor @Sendable (Int) -> Void) -> some View {
        Stepper(value: Binding(get: { value }, set: { newValue in onChange(newValue) }), in: range) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value)\(unit)").monospacedDigit()
            }
        }
        .frame(height: 33)
    }
}

struct OnboardingView: View {
    let context: AppContext

    var body: some View {
        ZStack {
            Color.tkBackground.opacity(0.92)
            VStack(alignment: .leading, spacing: 14) {
                Text("Welcome to jMacosTweaker").font(.system(size: 15, weight: .semibold))
                Text("Monitoring works right now, with no special access and no network.")
                Text("Fan control and the charge limit need a small root helper, because they change hardware settings. You install it yourself with one Terminal command, and can remove it the same way. The app never asks for your password.")
                    .foregroundStyle(Color.tkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Modules in the menu bar are independent. CPU and Memory are on to start with. Everything else is in Widgets.")
                    .foregroundStyle(Color.tkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(String(localized: "Start with monitoring")) {
                        context.settings.stored.hasCompletedOnboarding = true
                    }
                    .buttonStyle(InstrumentButtonStyle(primary: true))
                    Button(String(localized: "Show helper setup")) {
                        context.settings.stored.hasCompletedOnboarding = true
                        context.section = .settings
                    }
                    .buttonStyle(InstrumentButtonStyle())
                }
                .padding(.top, 6)
            }
            .padding(24)
            .frame(width: 440)
            .background(Color.tkBackground)
            .overlay(RoundedRectangle(cornerRadius: Tokens.Size.panelRadius).strokeBorder(Color.tkControl))
        }
    }
}
