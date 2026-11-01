import AppKit
import SwiftUI

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(sender)
    }
}

/// A borderless, solid panel anchored under a status item. `NSPopover` would add vibrancy and tint true black.
/// Content is created on open and released on close, so a closed panel costs nothing and holds no sampling demand.
@MainActor
final class PanelController {
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var openModule: Module?

    func toggle<Content: View>(module: Module?, anchor: NSStatusBarButton, @ViewBuilder content: () -> Content) {
        let wasOpen = panel?.isVisible == true
        let sameModule = openModule == module
        close()
        if wasOpen, sameModule { return }
        open(module: module, anchor: anchor, content: content())
    }

    private func open(module: Module?, anchor: NSStatusBarButton, content: some View) {
        guard let window = anchor.window else { return }
        let host = NSHostingView(rootView: content
            .frame(width: Tokens.Size.panelWidth)
            .background(Color.tkBackground)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Size.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Size.panelRadius).strokeBorder(Color.tkControl)))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.contentView = host
        panel.isReleasedWhenClosed = false
        panel.setContentSize(size)

        let anchorFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchorFrame.midX - size.width / 2, y: anchorFrame.minY - size.height - 6)
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = max(origin.y, screen.minY + 8)
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        openModule = module
        installMonitors()
    }

    func close() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        openModule = nil
    }

    /// Exists only while the panel is open, so a closed panel adds no event handling.
    private func installMonitors() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 {
                MainActor.assumeIsolated { self?.close() }
                return nil
            }
            return event
        }) {
            monitors.append(local)
        }
    }
}
