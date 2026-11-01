import AppKit
import Core
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsPage: View {
    let context: AppContext
    @State private var confirmingReset = false

    private static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private var helperVersion: String {
        guard let status = context.control.helper.status else { return String(localized: "Not connected") }
        return String(localized: "Connected, protocol \(status.protocolVersion)")
    }

    var body: some View {
        @Bindable var settings = context.settings
        PageScroll {
            PageHeader(title: WindowSection.settings.title)
            SectionLabel("Appearance").padding(.top, 20)
            Row(String(localized: "Theme")) {
                SegmentedPicker(
                    options: AppearanceChoice.allCases.map { ($0, $0.title) },
                    selection: $settings.stored.appearance,
                    label: String(localized: "Theme")
                )
                .frame(width: 240)
            }
            Row(String(localized: "Line accent")) { AccentPicker(settings: settings) }
            Row(String(localized: "Accent dividers")) {
                Toggle(String(localized: "Accent dividers"), isOn: $settings.stored.accentDividers)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(settings.stored.accent == .none)
            }
            Row(String(localized: "Temperature unit")) {
                SegmentedPicker(
                    options: TemperatureUnit.allCases.map { ($0, $0.title) },
                    selection: $settings.stored.temperatureUnit,
                    label: String(localized: "Temperature unit")
                )
                .frame(width: 120)
            }
            SectionLabel("General").padding(.top, 22)
            Row(String(localized: "Launch at login")) { LaunchAtLoginToggle() }
            Row(String(localized: "Settings file")) {
                HStack {
                    Button(String(localized: "Export…")) { exportSettings() }
                    Button(String(localized: "Import…")) { importSettings() }
                }
                .buttonStyle(InstrumentButtonStyle())
            }
            SectionLabel("Notifications").padding(.top, 22)
            Row(String(localized: "High temperature")) {
                Toggle(String(localized: "High temperature"), isOn: $settings.stored.notifyHighTemperature)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Row(String(localized: "Charge limit reached")) {
                Toggle(String(localized: "Charge limit reached"), isOn: $settings.stored.notifyChargeLimit)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if settings.stored.notifyHighTemperature {
                Row(String(localized: "Alert at")) {
                    HStack(spacing: 6) {
                        TextField("", value: Binding(
                            get: { Format.display(celsius: settings.stored.highTemperatureAt, unit: settings.stored.temperatureUnit) },
                            set: { settings.stored.highTemperatureAt = min(max(Format.celsius(display: $0, unit: settings.stored.temperatureUnit), 40), 120) }
                        ), format: .number.precision(.fractionLength(0)))
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        Text(settings.stored.temperatureUnit.title).foregroundStyle(Color.tkSecondary)
                    }
                }
            }
            SectionLabel("Privileged helper").padding(.top, 22)
            HelperSection(control: context.control)
            SectionLabel("About").padding(.top, 22)
            Row(String(localized: "Version")) { Text(Self.version).foregroundStyle(Color.tkSecondary) }
            Row(String(localized: "Helper")) { Text(helperVersion).foregroundStyle(Color.tkSecondary) }
            Row(String(localized: "GitHub")) {
                Link("github.com/volodya88i", destination: URL(string: "https://github.com/volodya88i")!)
                    .buttonStyle(.plain)
                    .underline()
                    .foregroundStyle(Color.tkSecondary)
            }
            Row(String(localized: "Reset all settings")) {
                Button(String(localized: "Reset…")) { confirmingReset = true }
                    .buttonStyle(InstrumentButtonStyle())
                    .confirmationDialog(String(localized: "Reset all settings?"), isPresented: $confirmingReset) {
                        Button(String(localized: "Reset"), role: .destructive) { context.control.resetAllSettings() }
                    } message: {
                        Text("Fans return to Auto and modules return to first-run choices. The macOS charge limit stays as it is.")
                    }
            }
            Row(String(localized: "Quit")) {
                Button(String(localized: "Quit jMacosTweaker")) { NSApp.terminate(nil) }
                    .buttonStyle(InstrumentButtonStyle())
            }
            #if DEBUG
            SectionLabel("Debug").padding(.top, 22)
            SelfMetricsView()
            #endif
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "jMacosTweaker-settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = context.settings.exportData() else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        if !context.settings.importData(data) { NSSound.beep() }
    }
}

private struct Row<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack {
                Text(title)
                Spacer()
                content
            }
            .frame(height: 41)
        }
    }
}

/// None keeps the pure black-and-white look. Warning and critical colors always override the accent.
private struct AccentPicker: View {
    @Bindable var settings: AppSettings

    private var customColor: Binding<Color> {
        Binding(
            get: {
                if case let .custom(hex) = settings.stored.accent { return Color(nsColor: NSColor(hex: hex)) }
                return Color(nsColor: Tokens.accent(settings.stored.accent))
            },
            set: { settings.stored.accent = .custom(NSColor($0).hexValue) }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AccentChoice.allCases, id: \.self) { choice in
                Button {
                    settings.stored.accent = choice
                } label: {
                    Circle()
                        .fill(Color(nsColor: Tokens.accent(choice)))
                        .frame(width: 14, height: 14)
                        .padding(3)
                        .overlay {
                            if settings.stored.accent == choice {
                                Circle().strokeBorder(Color.tkPrimary)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(choice.title)
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(settings.stored.accent == choice ? .isSelected : [])
            }
            ColorPicker(String(localized: "Custom color"), selection: customColor, supportsOpacity: false)
                .labelsHidden()
        }
    }
}

private struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var failed = false

    var body: some View {
        HStack {
            if failed {
                Text("Could not change this. Check Login Items in System Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.tkWarning)
            }
            Toggle(String(localized: "Launch at login"), isOn: Binding(
                get: { enabled },
                set: { value in
                    do {
                        if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        failed = false
                    } catch {
                        failed = true
                    }
                    enabled = SMAppService.mainApp.status == .enabled
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}
