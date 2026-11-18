import AppKit
import Core

/// Draws one or several widgets in a status item. A plain `NSView`, because SwiftUI hosting in the menu bar costs far
/// more per update. It redraws only when its content actually changes.
final class WidgetView: NSView {
    struct Entry: Equatable {
        var content: WidgetContent
        var style: WidgetStyle
        var showsLabel: Bool
        var history: [Float]
    }

    private static let labelFont = NSFont.systemFont(ofSize: 8, weight: .regular)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let singleLineFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private static let graphWidth: CGFloat = 28
    private static let gaugeSize: CGFloat = 15
    private static let gap: CGFloat = 12
    private static let margin: CGFloat = 3

    var entries: [Entry] = [] {
        didSet {
            guard entries != oldValue else { return }
            widths = entries.map(width)
            needsDisplay = true
        }
    }

    /// Per entry, worked out once per change and reused by drawing.
    private var widths: [CGFloat] = []

    private static let rightAligned: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        return style
    }()

    /// Text widths by font and string. Values repeat all the time ("42%", "61°"), and measuring was the largest cost of
    /// an idle app with the window closed.
    private static var measured: [String: CGFloat] = [:]

    private static func textWidth(_ string: String, _ font: NSFont, tag: Character) -> CGFloat {
        let key = "\(tag)\(string)"
        if let width = measured[key] { return width }
        if measured.count > 2000 { measured.removeAll(keepingCapacity: true) }
        let width = ceil((string as NSString).size(withAttributes: [.font: font]).width)
        measured[key] = width
        return width
    }

    var accent: NSColor = .labelColor {
        didSet {
            if accent != oldValue { needsDisplay = true }
        }
    }

    override var isFlipped: Bool { false }

    /// Hit testing goes to the status button under this view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func requiredWidth() -> CGFloat {
        guard !entries.isEmpty else { return 22 }
        return widths.reduce(0, +) + Self.gap * CGFloat(entries.count - 1) + Self.margin * 2
    }

    /// As wide as the text actually is, so there is no empty space beside it. Digits are monospaced, so an item only
    /// changes size when the number of digits does. Load modules swing between one and two digits all the time, so they
    /// always reserve two and do not push their neighbors around.
    private func valueSlot(_ entry: Entry) -> CGFloat {
        let single = entry.style == .iconValue || !entry.showsLabel
        let font = single ? Self.singleLineFont : Self.valueFont
        let tag: Character = single ? "s" : "v"
        var value = Self.textWidth(entry.content.value, font, tag: tag)
        if [Module.cpu, .memory, .gpu].contains(entry.content.module) {
            value = max(value, Self.textWidth("88%", font, tag: tag))
        }
        // Rates change length constantly, so these keep one steady width.
        if [Module.network, .disk].contains(entry.content.module) {
            value = max(value, Self.textWidth("888K", font, tag: tag))
        }
        guard !single else { return value }
        let label = Self.textWidth(entry.content.label ?? entry.content.module.shortLabel, Self.labelFont, tag: "l")
        return max(value, label)
    }

    private func width(_ entry: Entry) -> CGFloat {
        let slot = valueSlot(entry)
        switch entry.style {
        case .text: return slot
        case .iconValue: return slot + 18
        case .bar: return slot + 5 + 4
        case .sparkline: return slot + 5 + Self.graphWidth
        case .gauge: return slot + 5 + Self.gaugeSize
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        var x = Self.margin
        for (index, entry) in entries.enumerated() {
            let entryWidth = index < widths.count ? widths[index] : width(entry)
            draw(entry, in: NSRect(x: x, y: 0, width: entryWidth, height: bounds.height))
            x += entryWidth + Self.gap
        }
    }

    private func levelColor(_ level: ValueLevel) -> NSColor? {
        switch level {
        case .normal: nil
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }

    private func draw(_ entry: Entry, in rect: NSRect) {
        let textColor = levelColor(entry.content.level) ?? NSColor.labelColor
        let lineColor = levelColor(entry.content.level) ?? accent
        var textRect = rect
        switch entry.style {
        case .text:
            break
        case .iconValue:
            drawIcon(entry.content.module, in: NSRect(x: rect.minX, y: rect.midY - 8, width: 16, height: 16), color: textColor)
            textRect.origin.x += 18
            textRect.size.width -= 18
        case .bar:
            drawBar(entry.content.fraction ?? 0, in: NSRect(x: rect.maxX - 4, y: rect.midY - 8, width: 4, height: 16), color: lineColor)
            textRect.size.width -= 9
        case .sparkline:
            drawSparkline(entry.history, in: NSRect(x: rect.maxX - Self.graphWidth, y: rect.midY - 8, width: Self.graphWidth, height: 16), color: lineColor)
            textRect.size.width -= Self.graphWidth + 5
        case .gauge:
            let origin = NSPoint(x: rect.maxX - Self.gaugeSize, y: rect.midY - Self.gaugeSize / 2)
            drawGauge(entry.content.fraction ?? 0, at: origin, color: lineColor)
            textRect.size.width -= Self.gaugeSize + 5
        }
        if entry.style == .iconValue || !entry.showsLabel {
            drawSingleLine(entry.content.value, in: textRect, color: textColor)
        } else {
            drawStacked(label: entry.content.label ?? entry.content.module.shortLabel, value: entry.content.value, in: textRect, color: textColor)
        }
    }

    private func drawStacked(label: String, value: String, in rect: NSRect, color: NSColor) {
        (label as NSString).draw(
            in: NSRect(x: rect.minX, y: rect.midY + 1, width: rect.width, height: 10),
            withAttributes: [.font: Self.labelFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: Self.rightAligned]
        )
        (value as NSString).draw(
            in: NSRect(x: rect.minX, y: rect.midY - 12, width: rect.width, height: 15),
            withAttributes: [.font: Self.valueFont, .foregroundColor: color, .paragraphStyle: Self.rightAligned]
        )
    }

    private func drawSingleLine(_ value: String, in rect: NSRect, color: NSColor) {
        (value as NSString).draw(
            in: NSRect(x: rect.minX, y: rect.midY - 8.5, width: rect.width, height: 17),
            withAttributes: [.font: Self.singleLineFont, .foregroundColor: color, .paragraphStyle: Self.rightAligned]
        )
    }

    private func drawIcon(_ module: Module, in rect: NSRect, color: NSColor) {
        guard let base = NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil) else { return }
        let configured = base.withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) ?? base
        let tinted = NSImage(size: configured.size, flipped: false) { bounds in
            configured.draw(in: bounds)
            color.set()
            bounds.fill(using: .sourceIn)
            return true
        }
        let size = tinted.size
        tinted.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    private func drawBar(_ fraction: Double, in rect: NSRect, color: NSColor) {
        NSColor.tertiaryLabelColor.setFill()
        rect.fill()
        color.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * min(max(fraction, 0), 1)).fill()
    }

    private func drawSparkline(_ history: [Float], in rect: NSRect, color: NSColor) {
        guard history.count > 1 else { return }
        let top = max(history.max() ?? 1, 1)
        let path = NSBezierPath()
        path.lineWidth = 1
        let step = rect.width / CGFloat(history.count - 1)
        for (index, value) in history.enumerated() {
            let point = NSPoint(x: rect.minX + CGFloat(index) * step, y: rect.minY + 0.5 + CGFloat(value / top) * (rect.height - 1))
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        color.setStroke()
        path.stroke()
    }

    private func drawGauge(_ fraction: Double, at origin: NSPoint, color: NSColor) {
        let rect = NSRect(origin: origin, size: NSSize(width: Self.gaugeSize, height: Self.gaugeSize)).insetBy(dx: 1, dy: 1)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: rect.width / 2, startAngle: 225, endAngle: -45, clockwise: true)
        track.lineWidth = 2
        NSColor.tertiaryLabelColor.setStroke()
        track.stroke()
        let value = NSBezierPath()
        let end = 225 - 270 * CGFloat(min(max(fraction, 0), 1))
        value.appendArc(withCenter: center, radius: rect.width / 2, startAngle: 225, endAngle: end, clockwise: true)
        value.lineWidth = 2
        color.setStroke()
        value.stroke()
    }
}
