import AppKit
import Core
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsPage: View {
    let context: AppContext
    @State private var confirmingReset = false
    @State private var importFailed = false

    private static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        @Bindable var settings = context.settings
        Form {
            Section(String(localized: "Appearance")) {
                Picker(String(localized: "Appearance"), selection: $settings.stored.appearance) {
                    ForEach(AppearanceChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent(String(localized: "Graph color")) { AccentPicker(settings: settings) }
                Picker(String(localized: "Temperature unit"), selection: $settings.stored.temperatureUnit) {
                    ForEach(TemperatureUnit.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section(String(localized: "General")) {
                LaunchAtLoginToggle()
            }
            Section {
                Toggle(String(localized: "High temperature"), isOn: $settings.stored.notifyHighTemperature)
                if settings.stored.notifyHighTemperature {
                    LabeledContent(String(localized: "Alert at")) {
                        HStack(spacing: 6) {
                            TextField(String(localized: "Alert at"), value: Binding(
                                get: { Format.display(celsius: settings.stored.highTemperatureAt, unit: settings.stored.temperatureUnit) },
                                set: { value in
                                    guard value.isFinite else { return }
                                    settings.stored.highTemperatureAt = min(max(Format.celsius(display: value, unit: settings.stored.temperatureUnit), 40), 120)
                                }
                            ), format: .number.precision(.fractionLength(0)))
                            .labelsHidden()
                            .frame(width: 64)
                            Text(settings.stored.temperatureUnit.title).foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle(String(localized: "Charge limit reached"), isOn: $settings.stored.notifyChargeLimit)
            } header: {
                Text("Notifications")
            } footer: {
                Text("At most one notification of each kind every 15 minutes.").foregroundStyle(.secondary)
            }
            HelperSection(control: context.control)
            Section(String(localized: "Data")) {
                LabeledContent(String(localized: "Settings file")) {
                    HStack {
                        Button(String(localized: "Export…")) { exportSettings() }
                        Button(String(localized: "Import…")) { importSettings() }
                    }
                }
                LabeledContent(String(localized: "Reset all settings")) {
                    Button(String(localized: "Reset…"), role: .destructive) { confirmingReset = true }
                }
            }
            Section(String(localized: "About")) {
                LabeledContent(String(localized: "Version"), value: Self.version)
                LabeledContent(String(localized: "Source")) {
                    if let url = URL(string: "https://github.com/volodya88i/jMacosTweaker") {
                        Link("github.com/volodya88i/jMacosTweaker", destination: url)
                    }
                }
                LabeledContent(String(localized: "Quit")) {
                    Button(String(localized: "Quit jMacosTweaker")) { NSApp.terminate(nil) }
                }
            }
            #if DEBUG
            Section(String(localized: "Debug")) {
                SelfMetricsView()
            }
            #endif
        }
        .formStyle(.grouped)
        .confirmationDialog(String(localized: "Reset all settings?"), isPresented: $confirmingReset) {
            Button(String(localized: "Reset"), role: .destructive) { context.control.resetAllSettings() }
        } message: {
            Text("Fans return to Auto and modules return to first-run choices. The macOS charge limit stays as it is.")
        }
        .alert(String(localized: "This file could not be imported."), isPresented: $importFailed) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text("It is not a jMacosTweaker settings file, or it is from a newer version.")
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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // A settings file is a few kilobytes. Anything far larger is not one.
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_000_000,
              let data = try? Data(contentsOf: url), context.settings.importData(data) else {
            importFailed = true
            return
        }
    }
}

/// "System" follows the user's accent color. Warning and critical colors always override it.
private struct AccentPicker: View {
    @Bindable var settings: AppSettings

    private var customColor: Binding<Color> {
        Binding(
            get: { Tokens.accent(settings.stored.accent) },
            set: { settings.stored.accent = .custom(NSColor($0).hexValue) }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AccentChoice.allCases, id: \.self) { choice in
                Button {
                    settings.stored.accent = choice
                } label: {
                    Circle()
                        .fill(choice == .none
                              ? AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center))
                              : AnyShapeStyle(Tokens.accent(choice)))
                        .frame(width: 16, height: 16)
                        .overlay {
                            if settings.stored.accent == choice {
                                Circle().fill(.white).frame(width: 6, height: 6)
                            }
                        }
                        .padding(2)
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
    // Read once when the row appears. As an initial value it was asked of the system on every redraw of the page,
    // because SwiftUI evaluates that expression each time the view is created.
    @State private var enabled = false
    @State private var failed = false

    var body: some View {
        Toggle(isOn: Binding(
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
        )) {
            Text("Open at login")
            if failed {
                Text("Could not change this. Check Login Items in System Settings.")
                    .foregroundStyle(.orange)
            }
        }
        .task { enabled = SMAppService.mainApp.status == .enabled }
    }
}
