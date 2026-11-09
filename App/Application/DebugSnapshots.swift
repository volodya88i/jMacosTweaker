#if DEBUG
import AppKit
import Core
import SwiftUI

/// `--snapshots <dir>` renders every page and panel with live data to PNG, in both appearances, then quits.
/// Debug builds only. It exists because a command-line run cannot capture the screen without a permission grant.
@MainActor
enum DebugSnapshots {
    static func runIfRequested(context: AppContext, settings: AppSettings) {
        let arguments = CommandLine.arguments
        if arguments.contains("--open-window") { context.openWindow(.dashboard) }
        guard let flag = arguments.firstIndex(of: "--snapshots"), arguments.indices.contains(flag + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[flag + 1])
        if arguments.contains("--accent") { settings.stored.accent = .blue }
        Task {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for appearanceName in [NSAppearance.Name.darkAqua, .aqua] {
                NSApp.appearance = NSAppearance(named: appearanceName)
                let suffix = appearanceName == .darkAqua ? "dark" : "light"
                for section in WindowSection.allCases where context.isAvailable(section) {
                    context.section = section
                    await renderWindow(context: context, to: directory.appendingPathComponent("\(section.rawValue)-\(suffix).png"))
                }
                for module in Module.allCases + [nil] as [Module?] {
                    let name = module?.rawValue ?? "overview"
                    let view = PanelRoot(context: context, module: module)
                        .background(Color(nsColor: .windowBackgroundColor))
                    await render(view, size: nil, to: directory.appendingPathComponent("panel-\(name)-\(suffix).png"))
                }
                renderWidgets(to: directory.appendingPathComponent("module-styles-\(suffix).png"))
            }
            NSApp.terminate(nil)
        }
    }

    /// The real window, toolbar included, captured from its frame view.
    private static func renderWindow(context: AppContext, to url: URL) async {
        let controller = NSHostingController(rootView: RootView(context: context))
        controller.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: controller)
        window.title = context.section.title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1080, height: 740))
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderBack(nil)
        try? await Task.sleep(for: .seconds(4))
        write(window.contentView?.superview ?? controller.view, to: url)
        window.orderOut(nil)
        window.contentViewController = nil
    }

    private static func render(_ view: some View, size: CGSize?, to url: URL) async {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        // Long enough for several samples, so graphs and rates have data.
        try? await Task.sleep(for: .seconds(4))
        let fitted = size ?? host.fittingSize
        window.setContentSize(fitted)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
        write(host, to: url)
        window.orderOut(nil)
        window.contentView = nil
    }

    private static func renderWidgets(to url: URL) {
        let history: [Float] = [8, 9, 12, 18, 30, 26, 14, 11, 16, 22, 19, 12]
        var entries: [WidgetView.Entry] = []
        for (module, value, fraction) in [(Module.cpu, "11%", 0.11), (.memory, "70%", 0.7), (.gpu, "22%", 0.22), (.temperature, "42°", 0.42), (.fans, "2,380", 0.3), (.battery, "62%", 0.62), (.power, "18 W", nil)] as [(Module, String, Double?)] {
            for style in module.allowedStyles {
                entries.append(.init(content: WidgetContent(module: module, value: value, fraction: fraction), style: style, showsLabel: true, history: history))
            }
        }
        entries.append(.init(content: WidgetContent(module: .temperature, value: "96°", fraction: 0.96, level: .critical), style: .sparkline, showsLabel: true, history: history))
        let rows = stride(from: 0, to: entries.count, by: 8).map { Array(entries[$0..<min($0 + 8, entries.count)]) }
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: rows.count * 28))
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        for (index, row) in rows.enumerated() {
            let view = WidgetView(frame: NSRect(x: 0, y: (rows.count - index - 1) * 28, width: 620, height: 24))
            view.entries = row
            stack.addSubview(view)
        }
        write(stack, to: url)
    }

    private static func write(_ view: NSView, to url: URL) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
