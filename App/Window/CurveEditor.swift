import Core
import Shared
import SwiftUI

/// Drag points to edit. Double-click empty space to add a point, double-click a point to remove it.
/// Points stay monotonic because each one is constrained between its neighbors while dragging.
struct CurveEditor: View {
    let curve: FanCurve
    let isEditable: Bool
    /// Where the control temperature sits now.
    var currentTemperature: Double?
    let onCommit: (FanCurve) -> Void

    @State private var draft: FanCurve?
    @State private var dragIndex: Int?
    @Environment(\.lineStyle) private var style

    private static let temperatures = 30.0...100.0
    private static let height: CGFloat = 220
    private var shown: FanCurve { draft ?? curve }

    private func position(_ point: CurvePoint, in size: CGSize) -> CGPoint {
        let range = Self.temperatures
        return CGPoint(
            x: (point.temperature - range.lowerBound) / (range.upperBound - range.lowerBound) * size.width,
            y: (1 - point.percent / 100) * size.height
        )
    }

    private func point(at location: CGPoint, in size: CGSize) -> CurvePoint {
        let range = Self.temperatures
        let temperature = range.lowerBound + Double(location.x / size.width) * (range.upperBound - range.lowerBound)
        let percent = (1 - Double(location.y / size.height)) * 100
        return CurvePoint(temperature: temperature.rounded(), percent: min(max(percent.rounded(), 0), 100))
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(isEditable ? drag(size) : nil)
            .simultaneousGesture(isEditable ? SpatialTapGesture(count: 2).onEnded { doubleTap($0.location, size: size) } : nil)
            .overlay(alignment: .topLeading) {
                ForEach(Array(shown.points.enumerated()), id: \.offset) { index, point in
                    Color.clear
                        .frame(width: 1, height: 1)
                        .position(position(point, in: size))
                        .accessibilityElement()
                        .accessibilityLabel(String(localized: "Curve point at \(Int(point.temperature)) degrees"))
                        .accessibilityValue(String(localized: "\(Int(point.percent)) percent"))
                        .accessibilityAdjustableAction { direction in
                            guard isEditable else { return }
                            adjust(index: index, by: direction == .increment ? 5 : -5)
                        }
                }
            }
        }
        .frame(height: Self.height)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        for percent in stride(from: 0, through: 100, by: 25) {
            let y = (1 - CGFloat(percent) / 100) * size.height
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }, with: .color(style.divider), lineWidth: 1)
            context.draw(Text("\(percent)%").font(.system(size: 10)).foregroundStyle(Color.tkSecondary), at: CGPoint(x: 2, y: max(y - 7, 7)), anchor: .leading)
        }
        for temperature in stride(from: 40, through: 90, by: 10) {
            let x = (Double(temperature) - 30) / 70 * size.width
            context.draw(Text("\(temperature)°").font(.system(size: 10)).foregroundStyle(Color.tkSecondary), at: CGPoint(x: x, y: size.height - 7), anchor: .center)
        }

        let points = shown.points.map { position($0, in: size) }
        guard let first = points.first, let last = points.last else { return }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: first.y))
        for point in points { path.addLine(to: point) }
        path.addLine(to: CGPoint(x: size.width, y: last.y))
        context.stroke(path, with: .color(style.line), lineWidth: 1.5)
        for point in points {
            let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            context.fill(Path(rect), with: .color(isEditable ? style.line : style.secondaryLine))
        }

        if let currentTemperature {
            let range = Self.temperatures
            let x = (min(max(currentTemperature, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound) * size.width
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(.tkSecondary), lineWidth: 1)
            let y = (1 - CurveMath.percent(at: currentTemperature, curve: shown) / 100) * size.height
            context.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)), with: .color(.tkPrimary))
        }
    }

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                var working = shown
                if dragIndex == nil {
                    dragIndex = nearest(to: value.startLocation, in: size)
                }
                guard let index = dragIndex else { return }
                working.points[index] = constrained(point(at: value.location, in: size), index: index, in: working)
                draft = working
            }
            .onEnded { _ in
                dragIndex = nil
                if let draft { commit(draft) }
            }
    }

    private func nearest(to location: CGPoint, in size: CGSize) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, candidate) in shown.points.enumerated() {
            let p = position(candidate, in: size)
            let distance = hypot(p.x - location.x, p.y - location.y)
            if distance < 24, distance < (best?.distance ?? .infinity) { best = (index, distance) }
        }
        return best?.index
    }

    private func constrained(_ point: CurvePoint, index: Int, in curve: FanCurve) -> CurvePoint {
        var result = point
        let previous = index > 0 ? curve.points[index - 1] : nil
        let next = index < curve.points.count - 1 ? curve.points[index + 1] : nil
        let lowTemperature = (previous?.temperature ?? Self.temperatures.lowerBound - 1) + 1
        let highTemperature = (next?.temperature ?? Self.temperatures.upperBound + 1) - 1
        result.temperature = min(max(result.temperature, lowTemperature), highTemperature)
        result.percent = min(max(result.percent, previous?.percent ?? 0), next?.percent ?? 100)
        return result
    }

    private func doubleTap(_ location: CGPoint, size: CGSize) {
        var working = shown
        if let index = nearest(to: location, in: size) {
            guard working.points.count > 2 else { return }
            working.points.remove(at: index)
        } else {
            let added = point(at: location, in: size)
            guard !working.points.contains(where: { $0.temperature == added.temperature }) else { return }
            let index = working.points.firstIndex { $0.temperature > added.temperature } ?? working.points.count
            working.points.insert(added, at: index)
            working.points[index] = constrained(added, index: index, in: working)
        }
        commit(working)
    }

    private func adjust(index: Int, by delta: Double) {
        var working = shown
        var point = working.points[index]
        point.percent += delta
        working.points[index] = constrained(point, index: index, in: working)
        commit(working)
    }

    private func commit(_ candidate: FanCurve) {
        draft = nil
        onCommit(candidate)
    }
}
