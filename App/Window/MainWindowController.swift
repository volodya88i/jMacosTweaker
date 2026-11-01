import AppKit
import SwiftUI

/// The main window. Its content is released on close, which removes all of its sampling demand.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let context: AppContext
    private var window: NSWindow?

    init(context: AppContext) {
        self.context = context
    }

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "jMacosTweaker"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = Tokens.background
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 560)
        window.contentView = NSHostingView(rootView: RootView(context: context))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("main")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
