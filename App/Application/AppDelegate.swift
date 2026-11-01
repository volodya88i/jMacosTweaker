import AppKit
import Core
import IOKit.ps
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var store = MonitorStore(readers: HardwareFactory.makeReaders())
    private lazy var control = ControlModel(settings: settings, store: store)
    private lazy var context = AppContext(settings: settings, store: store, control: control)
    private lazy var alerts = AlertManager(settings: settings, store: store)
    private let panels = PanelController()
    private var menuBar: MenuBarController?
    private var windows: MainWindowController?
    private var powerSource: CFRunLoopSource?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance()
        NSApp.mainMenu = Self.makeMainMenu()
        context.openWindow = { [weak self] section in self?.showWindow(section) }
        context.closePanel = { [weak self] in self?.panels.close() }

        let menuBar = MenuBarController(
            settings: settings,
            store: store,
            onOpen: { [weak self] module, button in self?.openPanel(module, anchor: button) },
            onContextMenu: { [weak self] button in self?.showContextMenu(button) }
        )
        self.menuBar = menuBar
        menuBar.onFitChanged = { [weak self] hidden in self?.context.modulesHiddenByMenuBar = hidden }
        store.onBatch = { [weak self, weak menuBar] _ in
            menuBar?.refresh()
            self?.alerts.evaluate()
            self?.control.powerSourceChanged()
        }
        menuBar.settingsChanged()
        alerts.chargeLimit = { [weak self] in self?.control.nativeChargeLimit }
        alerts.settingsChanged()
        control.start()
        trackSettings()
        installSystemObservers()
        if !settings.stored.hasCompletedOnboarding, !CommandLine.arguments.contains("--snapshots") {
            showWindow(.dashboard)
        }
        #if DEBUG
        DebugSnapshots.runIfRequested(context: context, settings: settings)
        #endif
    }

    /// Copy, paste and window shortcuts are handled through the main menu, so without it they do nothing.
    private static func makeMainMenu() -> NSMenu {
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            items.forEach(submenu.addItem)
            holder.submenu = submenu
            return holder
        }
        func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
            NSMenuItem(title: title, action: action, keyEquivalent: key)
        }
        let main = NSMenu()
        main.addItem(menu("jMacosTweaker", [
            item(String(localized: "Hide jMacosTweaker"), #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item(String(localized: "Quit jMacosTweaker"), #selector(NSApplication.terminate(_:)), "q")
        ]))
        main.addItem(menu(String(localized: "Edit"), [
            item(String(localized: "Undo"), Selector(("undo:")), "z"),
            item(String(localized: "Redo"), Selector(("redo:")), "Z"),
            .separator(),
            item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"),
            item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"),
            item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"),
            item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a")
        ]))
        main.addItem(menu(String(localized: "Window"), [
            item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(String(localized: "Close"), #selector(NSWindow.performClose(_:)), "w")
        ]))
        return main
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(context.section)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Re-arms after each change, so settings edits update the menu bar without any polling.
    private func trackSettings() {
        withObservationTracking {
            _ = settings.stored
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyAppearance()
                self.menuBar?.settingsChanged()
                self.alerts.settingsChanged()
                self.control.settingsChanged()
                self.trackSettings()
            }
        }
    }

    private func applyAppearance() {
        switch settings.stored.appearance {
        case .system: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    private func openPanel(_ module: Module?, anchor: NSStatusBarButton) {
        let context = context
        panels.toggle(module: module, anchor: anchor) {
            PanelRoot(context: context, module: module)
        }
    }

    private func showWindow(_ section: WindowSection) {
        panels.close()
        context.section = section
        if windows == nil { windows = MainWindowController(context: context) }
        windows?.show()
    }

    private func showContextMenu(_ button: NSStatusBarButton) {
        let menu = NSMenu()
        let open = NSMenuItem(title: String(localized: "Open jMacosTweaker"), action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: button)
    }

    @objc private func openFromMenu() {
        showWindow(context.section)
    }

    private func installSystemObservers() {
        let engine = store.engine
        let workspace = NSWorkspace.shared.notificationCenter
        func pause(on name: Notification.Name, paused: Bool) {
            let token = workspace.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { await engine.setPaused(paused) }
            }
            observers.append((workspace, token))
        }
        pause(on: NSWorkspace.willSleepNotification, paused: true)
        pause(on: NSWorkspace.didWakeNotification, paused: false)
        pause(on: NSWorkspace.screensDidSleepNotification, paused: true)
        pause(on: NSWorkspace.screensDidWakeNotification, paused: false)

        let local = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            let token = local.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { await engine.setRateMultiplier(Self.rateMultiplier()) }
            }
            observers.append((local, token))
        }
        Task { await engine.setRateMultiplier(Self.rateMultiplier()) }
        installPowerSourceObserver()
    }

    private nonisolated static func rateMultiplier() -> Double {
        let info = ProcessInfo.processInfo
        if info.thermalState == .serious || info.thermalState == .critical { return 3 }
        return info.isLowPowerModeEnabled ? 2 : 1
    }

    /// Power source changes arrive from the OS, so a plug or unplug shows at once without faster polling.
    private func installPowerSourceObserver() {
        let context = Unmanaged.passUnretained(store.engine).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            let engine = Unmanaged<SamplingEngine>.fromOpaque(pointer).takeUnretainedValue()
            Task { await engine.expedite(.battery) }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }
}
