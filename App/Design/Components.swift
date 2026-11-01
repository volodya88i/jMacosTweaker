import Core
import SwiftUI

struct Hairline: View {
    @Environment(\.lineStyle) private var style

    var body: some View {
        Rectangle().fill(style.divider).frame(height: 1)
    }
}

struct VerticalHairline: View {
    @Environment(\.lineStyle) private var style

    var body: some View {
        Rectangle().fill(style.divider).frame(width: 1)
    }
}

/// A small caption above a block of rows.
struct SectionLabel: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.tkSecondary)
            .padding(.bottom, 10)
    }
}

/// A hairline-topped row with a label and a trailing value.
struct ValueRow<Trailing: View>: View {
    let title: String
    var secondary = false
    var height: CGFloat = Tokens.Size.windowRow
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack {
                Text(title)
                Spacer(minLength: 12)
                trailing.monospacedDigit()
            }
            .foregroundStyle(secondary ? Color.tkSecondary : Color.tkPrimary)
            .frame(height: height - 1)
        }
        .accessibilityElement(children: .combine)
    }
}

extension ValueRow where Trailing == Text {
    init(_ title: String, value: String, secondary: Bool = false, height: CGFloat = Tokens.Size.windowRow) {
        self.init(title: title, secondary: secondary, height: height) { Text(value) }
    }
}

/// One big light number with its unit.
struct BigNumber: View {
    let value: String
    var unit: String = ""
    var size: CGFloat = 38
    var color = Color.tkPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: size, weight: .light))
                .foregroundStyle(color)
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: size > 32 ? 15 : 13))
                    .foregroundStyle(Color.tkSecondary)
            }
        }
        .monospacedDigit()
    }
}

/// History graph. Drawn with `Canvas`, so a new sample redraws only this view.
struct Sparkline: View {
    let history: History
    /// Fixed scale keeps percentages honest. Nil scales to the visible maximum.
    var maximum: Float? = 100
    var color: Color?
    var height: CGFloat = 36

    @Environment(\.lineStyle) private var style

    var body: some View {
        Canvas { context, size in
            guard history.count > 1 else { return }
            var top = maximum ?? 0
            if maximum == nil {
                history.forEach { top = max(top, $0) }
                top = max(top * 1.1, 1)
            }
            // Fills the width from the first samples, so a graph never looks like a stub right after opening.
            let step = size.width / CGFloat(history.count - 1)
            var path = Path()
            var index = 0
            history.forEach { value in
                let x = CGFloat(index) * step
                let y = size.height - 0.5 - CGFloat(min(value / top, 1)) * (size.height - 1)
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                index += 1
            }
            context.stroke(path, with: .color(color ?? style.line), lineWidth: 1)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A thin filled bar.
struct MeterBar: View {
    let fraction: Double
    var height: CGFloat = 2
    var color: Color?
    /// Optional marker, such as the charge limit.
    var marker: Double?

    @Environment(\.lineStyle) private var style

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.tkTrack)
                Rectangle()
                    .fill(color ?? style.line)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                if let marker {
                    Rectangle()
                        .fill(color ?? style.line)
                        .frame(width: 1, height: height + 8)
                        .offset(x: geometry.size.width * min(max(marker, 0), 1))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Two segments of one bar: a share in the line color, and the rest muted.
struct SplitBar: View {
    let first: Double
    let second: Double
    @Environment(\.lineStyle) private var style

    var body: some View {
        GeometryReader { geometry in
            let total = max(first + second, 0.0001)
            HStack(spacing: 1) {
                Rectangle().fill(style.line).frame(width: max(geometry.size.width * first / total - 0.5, 0))
                Rectangle().fill(style.secondaryLine)
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

/// An outlined button, or a filled one for the primary action.
struct InstrumentButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: primary ? .medium : .regular))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .frame(maxWidth: primary ? .infinity : nil)
            .foregroundStyle(primary ? Color.tkBackground : Color.tkPrimary)
            .background(primary ? Color.tkPrimary : Color.tkBackground)
            .overlay {
                if !primary {
                    RoundedRectangle(cornerRadius: Tokens.Size.controlRadius).strokeBorder(Color.tkControl)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Size.controlRadius))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

/// Outlined segmented control. The native one brings its own tinted chrome.
struct SegmentedPicker<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var label: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 { Rectangle().fill(Color.tkControl).frame(width: 1) }
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(selection == option.value ? Color.tkBackground : Color.tkPrimary)
                        .background(selection == option.value ? Color.tkPrimary : Color.tkBackground)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option.value ? .isSelected : [])
            }
        }
        .frame(height: 28)
        .overlay(RoundedRectangle(cornerRadius: Tokens.Size.controlRadius).strokeBorder(Color.tkControl))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Size.controlRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// Registers sampling demand while a view is on screen. Nothing on screen means no polling.
struct SamplingModifier: ViewModifier {
    let engine: SamplingEngine
    let sources: Set<SampleSource>
    let interval: TimeInterval

    func body(content: Content) -> some View {
        content.task(id: sources) {
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

extension View {
    func sampling(_ sources: Set<SampleSource>, every interval: TimeInterval = 1, engine: SamplingEngine) -> some View {
        modifier(SamplingModifier(engine: engine, sources: sources, interval: interval))
    }
}
