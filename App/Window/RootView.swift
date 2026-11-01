import SwiftUI

struct RootView: View {
    let context: AppContext

    var body: some View {
        @Bindable var context = context
        HStack(spacing: 0) {
            Sidebar(selection: $context.section, context: context)
            VerticalHairline()
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.tkPrimary)
        .background(Color.tkBackground)
        .environment(\.lineStyle, LineStyle(accent: context.settings.stored.accent, accentDividers: context.settings.stored.accentDividers))
        .overlay {
            if !context.settings.stored.hasCompletedOnboarding, !CommandLine.arguments.contains("--snapshots") {
                OnboardingView(context: context)
            }
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
    @Binding var selection: WindowSection
    let context: AppContext

    private var sections: [WindowSection] {
        WindowSection.allCases.filter { section in
            switch section {
            case .fans: context.store.availability.hasFans
            case .battery: context.store.availability.hasBattery
            default: true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(sections) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.symbol).frame(width: 16)
                        Text(section.title)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .foregroundStyle(selection == section ? Color.tkPrimary : Color.tkSecondary)
                    .background(selection == section ? Color.tkSelection : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Size.controlRadius))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == section ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 44)
        .frame(width: Tokens.Size.sidebarWidth)
    }
}

/// Page header: title, one status line, optional trailing control, then a hairline.
struct PageHeader<Trailing: View>: View {
    let title: String
    var detail: String?
    var detailLevel = ValueLevel.normal
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if let detail {
                    Text(detail).foregroundStyle(LevelColor.color(detailLevel, fallback: .tkSecondary))
                }
                Spacer()
                trailing
            }
            .padding(.bottom, 16)
            Hairline()
        }
        .padding(.top, 16)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

/// Scrolling page body with the standard margins.
struct PageScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.automatic)
    }
}
