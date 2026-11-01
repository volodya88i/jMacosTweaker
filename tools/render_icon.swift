// Draws the app icon at every macOS size. Usage: swift tools/render_icon.swift
import AppKit

let folder = "App/Resources/Assets.xcassets/AppIcon.appiconset"
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)

func draw(_ c: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / 1024
    let white = { (alpha: CGFloat) in CGColor(red: 1, green: 1, blue: 1, alpha: alpha) }
    let bright = CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    let accent = CGColor(red: 0.35, green: 0.82, blue: 0.76, alpha: 1)
    func line(_ a: CGPoint, _ b: CGPoint, _ width: CGFloat, _ color: CGColor) {
        c.setLineCap(.round); c.setLineWidth(width); c.setStrokeColor(color)
        c.move(to: a); c.addLine(to: b); c.strokePath()
    }

    let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    c.saveGState()
    // Shadows ignore the context scale.
    c.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 34 * scale, color: CGColor(gray: 0, alpha: 0.45))
    c.addPath(shape); c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(shape); c.clip()
    let colors = [CGColor(gray: 0.13, alpha: 1), CGColor(gray: 0.02, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 300), options: [.drawsAfterEndLocation])
    c.restoreGState()
    c.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
    c.setStrokeColor(white(0.14)); c.setLineWidth(4); c.strokePath()

    // Fine ticks turn to noise at small sizes, so those get fewer and heavier ones.
    let small = pixels <= 64
    let center = CGPoint(x: 512, y: 490)
    let start = 225.0, sweep = 270.0, needleAt = 0.64
    let count = small ? 8 : 28
    for i in 0...count {
        let t = Double(i) / Double(count)
        let angle = (start - sweep * t) * .pi / 180
        let major = small || i % 7 == 0
        let inner: CGFloat = small ? 240 : (major ? 228 : 262), outer: CGFloat = 310
        let width: CGFloat = small ? 44 : (major ? 20 : 12)
        line(CGPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)),
             CGPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)), width, t <= needleAt ? bright : white(0.3))
    }
    let angle = (start - sweep * needleAt) * .pi / 180
    line(center, CGPoint(x: center.x + 208 * cos(angle), y: center.y + 208 * sin(angle)), small ? 44 : 22, accent)
    c.setFillColor(accent); c.fillEllipse(in: CGRect(x: center.x - 44, y: center.y - 44, width: 88, height: 88))
    if !small {
        c.setFillColor(CGColor(gray: 0.04, alpha: 1)); c.fillEllipse(in: CGRect(x: center.x - 16, y: center.y - 16, width: 32, height: 32))
    }
}

for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(context, pixels: pixels)
    context.flush()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(folder)/icon_\(pixels).png"))
}
