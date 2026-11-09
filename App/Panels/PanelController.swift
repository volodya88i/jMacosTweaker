import AppKit
import SwiftUI

/// A native popover under a status item. It gets the system material, and Liquid Glass on macOS 26 and later.
/// Content is created on open and released on close, so a closed popover costs nothing and holds no sampling demand.
@MainActor
final class PanelController: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private var openModule: Module?
    /// A click on the item that owns an open popover closes it on mouse down, before the item's action runs on mouse up.
    /// Without this, that same click would open it again at once.
    private var lastClose: (module: Module?, time: TimeInterval)?

    func toggle<Content: View>(module: Module?, anchor: NSStatusBarButton, @ViewBuilder content: () -> Content) {
        let now = ProcessInfo.processInfo.systemUptime
        if let popover, popover.isShown {
            let same = openModule == module
            close()
            if same { return }
        } else if let lastClose, lastClose.module == module, now - lastClose.time < 0.35 {
            self.lastClose = nil
            return
        }
        open(module: module, anchor: anchor, content: content())
    }

    private func open(module: Module?, anchor: NSStatusBarButton, content: some View) {
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        self.popover = popover
        openModule = module
        NSApp.activate()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        popover?.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        lastClose = (openModule, ProcessInfo.processInfo.systemUptime)
        closed.contentViewController = nil
        popover = nil
        openModule = nil
    }
}
