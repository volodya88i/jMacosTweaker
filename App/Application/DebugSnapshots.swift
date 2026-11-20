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
        if arguments.contains("--benchmark") { Task { await benchmark(context: context) } }
        if arguments.contains("--steady") { Task { await steady(context: context) } }
        guard let flag = arguments.firstIndex(of: "--snapshots"), arguments.indices.contains(flag + 1) else { return }
        let directory = URL(fileURLWithPath: arguments[flag + 1])
        // macOS may serve a cached icon for this bundle identifier; the catalog holds the one this build ships.
        if let icon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = icon }
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

    /// `--benchmark` switches pages in the real window, moved off screen, and reports how long the main thread stayed
    /// blocked after each switch. A background thread pings the main queue every 10 ms; a late reply is a stall.
    private static func benchmark(context: AppContext) async {
        context.openWindow(.dashboard)
        try? await Task.sleep(for: .seconds(2))
        if !CommandLine.arguments.contains("--onscreen") {
            NSApp.windows.first { $0.title == context.section.title }?.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        }
        let monitor = StallMonitor()
        monitor.start()
        try? await Task.sleep(for: .seconds(2))
        for round in 1...3 {
            for section in WindowSection.allCases where context.isAvailable(section) {
                monitor.reset()
                let start = ContinuousClock.now
                context.section = section
                await Task.yield()
                let set = ContinuousClock.now - start
                try? await Task.sleep(for: .milliseconds(1500))
                print(String(format: "round %d %-12@ worst stall %4.0f ms, total stalled %5.0f ms, set %3.0f ms",
                             round, section.rawValue, monitor.worst * 1000, monitor.total * 1000, Double(set.components.attoseconds) / 1e15))
            }
        }
        monitor.stop()
        NSApp.terminate(nil)
    }

    /// `--steady` measures this process's CPU time with the window closed, then on each page for 15 s, on screen.
    /// Run it with `--settings-suite <name>`, so the owner's settings are not touched.
    private static func steady(context: AppContext) async {
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        func measure(_ name: String, seconds: Double = 15) async {
            try? await Task.sleep(for: .seconds(3))
            let start = cpuSeconds()
            try? await Task.sleep(for: .seconds(seconds))
            print(String(format: "steady %-12@ %5.2f%% CPU", name, (cpuSeconds() - start) / seconds * 100))
        }
        try? await Task.sleep(for: .seconds(3))
        // `--steady-only <section>` stays on one page for a minute, for attaching `sample`.
        if let flag = CommandLine.arguments.firstIndex(of: "--steady-only"), CommandLine.arguments.indices.contains(flag + 1),
           let section = WindowSection(rawValue: CommandLine.arguments[flag + 1]) {
            context.openWindow(section)
            await measure(section.rawValue, seconds: 60)
            NSApp.terminate(nil)
            return
        }
        await measure("closed")
        context.openWindow(.dashboard)
        for section in WindowSection.allCases where context.isAvailable(section) {
            context.section = section
            await measure(section.rawValue)
        }
        NSApp.windows.first { $0.title == context.section.title }?.close()
        await measure("reclosed")
        NSApp.terminate(nil)
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
        // `--tall` shows long pages whole, such as the curve editor at the bottom of Fans.
        window.setContentSize(NSSize(width: 1080, height: CommandLine.arguments.contains("--tall") ? 1500 : 740))
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderBack(nil)
        // Pages sample every 2 s, and load figures need two samples, so 4 s could still show a dash.
        try? await Task.sleep(for: .seconds(6))
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
/// Measures how late the main queue answers. Debug builds only.
final class StallMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var worstValue = 0.0
    private var totalValue = 0.0

    var worst: Double { lock.withLock { worstValue } }
    var total: Double { lock.withLock { totalValue } }

    func reset() { lock.withLock { worstValue = 0; totalValue = 0 } }

    func start() {
        lock.withLock { running = true }
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let sent = ProcessInfo.processInfo.systemUptime
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let late = ProcessInfo.processInfo.systemUptime - sent
                if late > 0.016 { lock.withLock { worstValue = max(worstValue, late); totalValue += late } }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    func stop() { lock.withLock { running = false } }
}
#endif
