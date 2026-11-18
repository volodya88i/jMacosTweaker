import Core
import Shared
import SwiftUI

/// Drag points to edit. Double-click empty space to add a point, double-click a point to remove it.
/// Points stay monotonic because each one is constrained between its neighbors while dragging, and never go below the
/// macOS minimum, drawn as a shaded zone.
struct CurveEditor: View {
    let curve: FanCurve
    let isEditable: Bool
    /// Where the control temperature sits now.
    var currentTemperature: Double?
    var unit: TemperatureUnit = .celsius
    let onCommit: (FanCurve) -> Void

    /// A drag either holds one point from start to end, or holds nothing. It never picks a point up halfway.
    private enum DragTarget: Equatable {
        case idle
        case point(Int)
        case nothing
    }

    @State private var draft: FanCurve?
    @State private var target = DragTarget.idle
    @Environment(\.dataTint) private var tint

    private static let temperatures = 30.0...100.0
    /// The trailing inset leaves room for the 100 °C label and a point sitting on it.
    private static let insets = EdgeInsets(top: 10, leading: 36, bottom: 20, trailing: 20)
    private static let height: CGFloat = 230
    private var shown: FanCurve { draft ?? curve }

    private static func plot(in size: CGSize) -> CGRect {
        CGRect(
            x: insets.leading, y: insets.top,
            width: max(size.width - insets.leading - insets.trailing, 1),
            height: max(size.height - insets.top - insets.bottom, 1)
        )
    }

    private static func x(_ temperature: Double, in plot: CGRect) -> CGFloat {
        plot.minX + CGFloat((temperature - temperatures.lowerBound) / (temperatures.upperBound - temperatures.lowerBound)) * plot.width
    }

    private static func y(_ percent: Double, in plot: CGRect) -> CGFloat {
        plot.maxY - CGFloat(percent / 100) * plot.height
    }

    private func position(_ point: CurvePoint, in size: CGSize) -> CGPoint {
        let plot = Self.plot(in: size)
        return CGPoint(x: Self.x(point.temperature, in: plot), y: Self.y(point.percent, in: plot))
    }

    private func point(at location: CGPoint, in size: CGSize) -> CurvePoint {
        let plot = Self.plot(in: size)
        let range = Self.temperatures
        let temperature = range.lowerBound + Double((location.x - plot.minX) / plot.width) * (range.upperBound - range.lowerBound)
        let percent = Double((plot.maxY - location.y) / plot.height) * 100
        return CurvePoint(
            temperature: min(max(temperature.rounded(), range.lowerBound), range.upperBound),
            percent: min(max(percent.rounded(), 0), 100)
        )
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
                        .accessibilityLabel(String(localized: "Curve point at \(Format.temperature(point.temperature, unit: unit))"))
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
        let plot = Self.plot(in: size)
        let grid = GraphicsContext.Shading.color(.secondary.opacity(0.2))
        for percent in stride(from: 0, through: 100, by: 25) {
            let y = Self.y(Double(percent), in: plot)
            context.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: y)); $0.addLine(to: CGPoint(x: plot.maxX, y: y)) }, with: grid, lineWidth: 0.5)
            context.draw(Text("\(percent)%").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
        }
        for temperature in stride(from: 40, through: 100, by: 10) {
            let x = Self.x(Double(temperature), in: plot)
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) }, with: grid, lineWidth: 0.5)
            context.draw(Text(Format.temperature(Double(temperature), unit: unit)).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: x, y: plot.maxY + 11), anchor: .center)
        }

        drawFloor(in: &context, plot: plot)

        let points = shown.points.map { position($0, in: size) }
        guard let first = points.first, let last = points.last else { return }
        var line = Path()
        line.move(to: CGPoint(x: plot.minX, y: first.y))
        for point in points { line.addLine(to: point) }
        line.addLine(to: CGPoint(x: plot.maxX, y: last.y))
        var area = line
        area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        area.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        area.closeSubpath()
        context.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.22), tint.opacity(0.02)]), startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
        context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

        if let currentTemperature {
            let clamped = min(max(currentTemperature, Self.temperatures.lowerBound), Self.temperatures.upperBound)
            let x = Self.x(clamped, in: plot)
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) }, with: .color(.orange.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            let y = Self.y(CurveMath.percent(at: currentTemperature, curve: shown), in: plot)
            context.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(.orange))
            let label = context.resolve(Text(Format.temperature(currentTemperature, unit: unit)).font(.caption2.weight(.semibold)).foregroundStyle(.orange))
            let labelSize = label.measure(in: size)
            context.draw(label, at: CGPoint(x: min(max(x, plot.minX + labelSize.width / 2), plot.maxX - labelSize.width / 2), y: plot.minY + 1), anchor: .top)
        }

        for (index, point) in points.enumerated() {
            let radius: CGFloat = target == .point(index) ? 6 : 4.5
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(isEditable ? tint : .secondary))
            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }
    }

    /// The weakest curve allowed. The helper applies it against the hottest CPU or GPU, so it holds whatever sensor the
    /// curve follows.
    private func drawFloor(in context: inout GraphicsContext, plot: CGRect) {
        let range = Self.temperatures
        var edge = Path()
        var temperature = range.lowerBound
        edge.move(to: CGPoint(x: Self.x(temperature, in: plot), y: Self.y(CurveMath.floorPercent(at: temperature), in: plot)))
        while temperature < range.upperBound {
            temperature = min(temperature + 1, range.upperBound)
            edge.addLine(to: CGPoint(x: Self.x(temperature, in: plot), y: Self.y(CurveMath.floorPercent(at: temperature), in: plot)))
        }
        var zone = edge
        zone.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        zone.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        zone.closeSubpath()
        context.fill(zone, with: .color(.secondary.opacity(0.12)))
        context.stroke(edge, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        // Inside the zone, in its corner, clear of the edge and of curve points at 100 °C.
        let label = context.resolve(Text("macOS minimum").font(.caption2).foregroundStyle(.secondary))
        context.draw(label, at: CGPoint(x: plot.maxX - 14, y: plot.maxY - 3), anchor: .bottomTrailing)
    }

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if target == .idle {
                    target = nearest(to: value.startLocation, in: size).map(DragTarget.point) ?? .nothing
                }
                guard case let .point(index) = target else { return }
                var working = shown
                working.points[index] = constrained(point(at: value.location, in: size), index: index, in: working)
                draft = working
            }
            .onEnded { _ in
                target = .idle
                if let draft { commit(draft) }
            }
    }

    private func nearest(to location: CGPoint, in size: CGSize) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, candidate) in shown.points.enumerated() {
            let p = position(candidate, in: size)
            let distance = hypot(p.x - location.x, p.y - location.y)
            if distance < 20, distance < (best?.distance ?? .infinity) { best = (index, distance) }
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
        let lowest = max(previous?.percent ?? 0, CurveMath.floorPercent(at: result.temperature))
        result.percent = min(max(result.percent, lowest), max(next?.percent ?? 100, lowest))
        return result
    }

    private func doubleTap(_ location: CGPoint, size: CGSize) {
        var working = shown
        if let index = nearest(to: location, in: size) {
            guard working.points.count > 2 else { return }
            working.points.remove(at: index)
        } else {
            let added = point(at: location, in: size)
            guard !working.points.contains(where: { abs($0.temperature - added.temperature) < 1 }) else { return }
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
