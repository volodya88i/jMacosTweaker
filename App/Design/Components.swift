import Core
import SwiftUI

// MARK: Containers

/// A rounded group, the same color as a grouped `Form` section in both appearances.
struct Card<Content: View>: View {
    var padding: CGFloat = Tokens.Size.cardPadding
    /// Fills the row's height, for rows sized to their tallest card. Off by default: a flexible height on every card
    /// makes SwiftUI measure each nested card several times per layout pass.
    var fillsHeight = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Tokens.Size.cardRadius, style: .continuous))
    }
}

/// Icon and title at the top of a card, with an optional accessory on the right.
struct CardHeader<Accessory: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            accessory
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

extension CardHeader where Accessory == EmptyView {
    init(symbol: String, title: String) {
        self.init(symbol: symbol, title: title) { EmptyView() }
    }
}

/// A scrolling page with the standard margins.
struct PageScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(Tokens.Size.pagePadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// A small caption above a group of cards, like a `Form` section header.
struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Values

/// One large number with its unit, in tabular figures so it does not jitter.
struct BigValue: View {
    let value: String
    var unit: String = ""
    var size: CGFloat = 30
    var color: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)
                .contentTransition(.identity)
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: max(size * 0.42, 11), weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
    }
}

/// A label and a value, as in a grouped form row.
struct InfoRow: View {
    let title: String
    let value: String
    var color: Color?

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(color ?? .secondary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 22)
        .accessibilityElement(children: .combine)
    }
}

/// Rows separated by inset dividers, the way a grouped form draws them.
struct InfoRows: View {
    struct Item: Identifiable {
        let title: String
        let value: String
        var color: Color?
        var id: String { title }
    }

    let items: [Item]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // By position: titles can repeat, such as two processes with the same name.
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider() }
                InfoRow(title: item.title, value: item.value, color: item.color)
            }
        }
    }
}

/// A colored capsule with a dot, for states such as Running or Manual.
struct StatusBadge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color == .secondary ? Color.secondary : color)
    }
}

/// The colored rounded square System Settings uses for its sidebar icons.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        // Scaled to fit a fixed box, so every glyph sits optically centered whatever its shape. Sizing by font
        // instead aligns glyphs to a text baseline, which left tall or wide ones visibly off-center.
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .fontWeight(.semibold)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size * 0.6, height: size * 0.6)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: Bars and graphs

/// A progress capsule. The optional marker shows a limit, such as the charge limit.
struct CapsuleBar: View {
    let fraction: Double
    var tint: Color?
    var height: CGFloat = 6
    var marker: Double?

    @Environment(\.dataTint) private var dataTint

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint ?? dataTint)
                    .frame(width: max(width * min(max(fraction, 0), 1), fraction > 0 ? height : 0))
                if let marker {
                    Capsule()
                        .fill(.primary.opacity(0.7))
                        .frame(width: 2, height: height + 6)
                        .offset(x: min(max(width * marker - 1, 0), width - 2))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// One bar split into colored parts, such as how memory is used.
struct StackedBar: View {
    struct Part: Identifiable {
        let title: String
        let value: Double
        let color: Color
        var id: String { title }
    }

    let parts: [Part]
    var total: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1.5) {
                ForEach(parts) { part in
                    Rectangle()
                        .fill(part.color)
                        .frame(width: max(geometry.size.width * part.value / max(total, 1) - 1.5, 0))
                }
                Spacer(minLength: 0)
            }
            .background(.quaternary)
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Small colored dots with labels, under a stacked bar.
struct Legend: View {
    let parts: [StackedBar.Part]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(parts) { part in
                HStack(spacing: 4) {
                    Circle().fill(part.color).frame(width: 7, height: 7)
                    Text(part.title)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// History graph with a soft fill. Drawn with `Canvas`, so a new sample redraws only this view.
struct Sparkline: View {
    let history: History
    /// Fixed scale keeps percentages honest. Nil scales to the visible maximum.
    var maximum: Float? = 100
    var tint: Color?
    var height: CGFloat = 36

    @Environment(\.dataTint) private var dataTint

    var body: some View {
        let color = tint ?? dataTint
        Canvas { context, size in
            guard history.count > 1 else { return }
            var top = maximum ?? 0
            if maximum == nil {
                history.forEach { top = max(top, $0) }
                top = max(top * 1.15, 1)
            }
            // Fills the width from the first samples, so a graph never looks like a stub right after opening.
            let step = size.width / CGFloat(history.count - 1)
            var line = Path()
            var index = 0
            history.forEach { value in
                let point = CGPoint(x: CGFloat(index) * step, y: size.height - 1 - CGFloat(min(max(value / top, 0), 1)) * (size.height - 2))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                index += 1
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [color.opacity(0.28), color.opacity(0.02)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: Notices

/// Explains why something is unavailable, and always says what to do next.
struct NoticeCard: View {
    let symbol: String
    let title: String
    let text: String
    var level = ValueLevel.normal
    var command: String?

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(LevelColor.color(level, fallback: .accentColor))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(text)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let command {
                        CommandLineView(command: command).padding(.top, 4)
                    }
                }
            }
        }
    }
}

/// An inline note in a card or form.
struct InlineNotice: View {
    let text: String
    var level = ValueLevel.normal

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: level == .normal ? "info.circle" : "exclamationmark.triangle.fill")
        }
        .font(.callout)
        .foregroundStyle(LevelColor.color(level, fallback: .secondary))
    }
}

/// A Terminal command the user can select or copy. The app never runs privileged commands itself.
struct CommandLineView: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(command)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            } label: {
                Label(copied ? String(localized: "Copied") : String(localized: "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: Liquid Glass with fallbacks

extension View {
    /// Liquid Glass on macOS 26 and later, the classic borderless look before it.
    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// The prominent version, for the one main action of a view.
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

// MARK: Sampling

/// Registers sampling demand while a view is on screen. Nothing on screen means no polling.
struct SamplingModifier: ViewModifier {
    let engine: SamplingEngine
    let sources: Set<SampleSource>
    let interval: TimeInterval

    func body(content: Content) -> some View {
        content.task(id: SamplingKey(sources: sources, interval: interval)) {
            guard !sources.isEmpty else { return }
            let token = await engine.register(SampleDemand(sources: sources, interval: interval))
            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3600))
                }
            } onCancel: {
                Task { await engine.remove(token) }
            }
        }
    }
}

private struct SamplingKey: Hashable {
    let sources: Set<SampleSource>
    let interval: TimeInterval
}

extension View {
    func sampling(_ sources: Set<SampleSource>, every interval: TimeInterval = 1, engine: SamplingEngine) -> some View {
        modifier(SamplingModifier(engine: engine, sources: sources, interval: interval))
    }
}
