import Core
import SwiftUI

/// The main window: a native sidebar and one page. On macOS 26 and later the sidebar and toolbar are Liquid Glass by
/// themselves, because both are stock components.
struct RootView: View {
    let context: AppContext

    var body: some View {
        @Bindable var context = context
        NavigationSplitView {
            Sidebar(context: context, selection: $context.section)
                .navigationSplitViewColumnWidth(min: 190, ideal: 212, max: 280)
        } detail: {
            page
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        // One toolbar for the whole window, attached outside the page switch and never changed by a page. Rebuilding it
        // on every switch was slow, and a page without it made the title bar shorter, so the window buttons jumped.
        .toolbar {
            ToolbarItem(placement: .primaryAction) { RestoreButton(control: context.control) }
        }
        .environment(\.dataTint, context.dataTint)
        .sheet(isPresented: Binding(
            get: { !context.settings.stored.hasCompletedOnboarding && !CommandLine.arguments.contains("--snapshots") },
            set: { if !$0 { context.settings.stored.hasCompletedOnboarding = true } }
        )) {
            OnboardingView(context: context)
        }
    }

    @ViewBuilder private var page: some View {
        switch context.section {
        case .dashboard: DashboardPage(context: context)
        case .fans: FansPage(context: context)
        case .sensors: SensorsPage(context: context)
        case .performance: PerformancePage(context: context)
        case .battery: BatteryPage(context: context)
        case .widgets: WidgetsPage(context: context)
        case .settings: SettingsPage(context: context)
        }
    }
}

private struct Sidebar: View {
    let context: AppContext
    @Binding var selection: WindowSection

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let value = $0 { selection = value } })) {
            Section(String(localized: "Monitoring")) { rows(WindowSection.monitoring) }
            if WindowSection.control.contains(where: context.isAvailable) {
                Section(String(localized: "Control")) { rows(WindowSection.control) }
            }
            Section(String(localized: "App")) { rows(WindowSection.app) }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let release = context.updates.noticeRelease {
                UpdateNotice(release: release, updates: context.updates)
            }
        }
    }

    private func rows(_ sections: [WindowSection]) -> some View {
        ForEach(sections.filter(context.isAvailable)) { section in
            Label {
                Text(section.title)
            } icon: {
                SettingsIcon(symbol: section.symbol, color: section.tint)
            }
            .tag(section)
        }
    }
}

/// A newer release, at the foot of the sidebar. Opens the release page; never downloads anything.
private struct UpdateNotice: View {
    let release: LatestRelease
    let updates: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(String(localized: "Version \(release.version.description) is available"), systemImage: "arrow.down.circle")
                .font(.callout.weight(.medium))
            HStack(spacing: 8) {
                Link(String(localized: "Release Notes"), destination: release.pageURL)
                Spacer()
                Button(String(localized: "Later")) { updates.dismiss() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(10)
    }
}

/// First run: what works now, what needs the helper, and that the app never asks for a password.
struct OnboardingView: View {
    let context: AppContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text("Welcome to jMacosTweaker")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 14) {
                feature("chart.xyaxis.line", .blue, String(localized: "Monitoring works right away"),
                        String(localized: "Temperatures, fans, load and power, with no special access and no network."))
                feature("fan.fill", .cyan, String(localized: "Fan control needs a small helper"),
                        String(localized: "It changes hardware settings, so it runs as root. You install it with one Terminal command and can remove it the same way. The app never asks for your password."))
                feature("menubar.rectangle", .indigo, String(localized: "You choose the menu bar"),
                        String(localized: "CPU and Memory are on to start with. Everything else is under Menu Bar."))
            }
            .frame(maxWidth: 380)
            HStack {
                Button(String(localized: "Set Up Helper…")) {
                    context.settings.stored.hasCompletedOnboarding = true
                    context.section = .settings
                    dismiss()
                }
                .glassButton()
                Spacer()
                Button(String(localized: "Continue")) {
                    context.settings.stored.hasCompletedOnboarding = true
                    dismiss()
                }
                .glassProminentButton()
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 460)
    }

    private func feature(_ symbol: String, _ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
