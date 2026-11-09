import AppKit
import SwiftUI

/// The main window. Its content is released on close, which removes all of its sampling demand.
/// SwiftUI owns the toolbar and subtitle through scene bridging, so pages declare them the native way. The title is set
/// here: in an AppKit-hosted split view SwiftUI does not bridge `navigationTitle` and leaves the window "Untitled".
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
        let controller = NSHostingController(rootView: RootView(context: context))
        controller.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "jMacosTweaker"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 560)
        window.setContentSize(NSSize(width: 1080, height: 740))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("main.v2")
        trackTitle(of: window)
        return window
    }

    /// Follows the selected section. Re-arms after each change, so nothing polls.
    private func trackTitle(of window: NSWindow) {
        window.title = withObservationTracking {
            context.section.title
        } onChange: { [weak self, weak window] in
            Task { @MainActor in
                guard let self, let window, self.window === window else { return }
                self.trackTitle(of: window)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
