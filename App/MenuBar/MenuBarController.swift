import AppKit
import Core

/// Owns the status items. Each enabled module is an independent item with its own demand; a disabled module has no
/// item and causes no polling. A plain app icon appears whenever nothing else would be visible.
@MainActor
final class MenuBarController: NSObject {
    @MainActor private final class Slot {
        let item: NSStatusItem
        let view = WidgetView()
        init(item: NSStatusItem) { self.item = item }
    }

    private static let fallbackKey = "fallback"
    private static let combinedKey = "combined"

    private let settings: AppSettings
    private let store: MonitorStore
    private let onOpen: (Module?, NSStatusBarButton) -> Void
    private let onContextMenu: (NSStatusBarButton) -> Void

    private var slots: [String: Slot] = [:]
    private var visible: Set<Module> = []
    private var lastDemands: [SampleDemand] = []
    private var layout: [String] = []
    private var demandSync: Task<Void, Never>?
    /// Reports modules macOS could not fit, for example beside the notch.
    var onFitChanged: (([Module]) -> Void)?

    init(
        settings: AppSettings,
        store: MonitorStore,
        onOpen: @escaping (Module?, NSStatusBarButton) -> Void,
        onContextMenu: @escaping (NSStatusBarButton) -> Void
    ) {
        self.settings = settings
        self.store = store
        self.onOpen = onOpen
        self.onContextMenu = onContextMenu
        super.init()
    }

    private var enabledWidgets: [WidgetConfig] {
        settings.stored.widgets.filter { $0.enabled && store.availability.isAvailable($0.module) }
    }

    /// Call after any settings change.
    func settingsChanged() {
        updateDemands()
        rebuild()
        refresh()
    }

    /// Call after each sample batch.
    func refresh() {
        // A pinned sensor may need a lighter read once the sensor list is known. No change means no work here.
        updateDemands()
        // Each module's content is worked out once per batch and shared by the visibility check and the drawing.
        let unit = settings.stored.temperatureUnit
        let enabled = enabledWidgets
        var contents: [Module: WidgetContent] = [:]
        for config in enabled { contents[config.module] = WidgetEvaluator.content(for: config, store: store, unit: unit) }
        let visibleNow = computeVisibility(enabled, contents)
        if visibleNow != visible {
            visible = visibleNow
            rebuild()
        }
        update(enabled, contents)
    }

    private func computeVisibility(_ enabled: [WidgetConfig], _ contents: [Module: WidgetContent]) -> Set<Module> {
        var result = Set<Module>()
        for config in enabled {
            guard let content = contents[config.module] else { continue }
            if WidgetEvaluator.isVisible(
                rule: config.visibility, raw: content.rawValue, battery: store.battery.current,
                wasVisible: visible.contains(config.module)
            ) {
                result.insert(config.module)
            }
        }
        return result
    }

    private func demand(for config: WidgetConfig) -> SampleDemand {
        var sources = config.module.sources
        // A pinned sensor outside the summary groups needs the full read.
        if config.module == .temperature, let pinned = config.pinnedSensor, !store.sensors.isInSummary(pinned) { sources = [.temperatureFull] }
        // Rules on battery state need battery data even for another module.
        switch config.visibility {
        case .whileCharging, .onBattery: sources.insert(.battery)
        default: break
        }
        return SampleDemand(sources: sources, interval: config.interval)
    }

    private func updateDemands() {
        let wanted = enabledWidgets.map(demand)
        guard wanted != lastDemands else { return }
        lastDemands = wanted
        let engine = store.engine
        let previous = demandSync
        // Chained, so rapid toggles reach the engine in order.
        demandSync = Task {
            await previous?.value
            await engine.setDemands(owner: "widgets", wanted)
        }
    }

    /// Recreates items in order. New items appear to the left, so they are created from last to first.
    private func rebuild() {
        let shown = enabledWidgets.filter { visible.contains($0.module) }
        // Items are only recreated when the set or order changes. Anything else updates them in place, so changing a
        // setting does not make the menu bar flicker.
        let wanted = settings.stored.combined && !shown.isEmpty ? [Self.combinedKey] : shown.map(\.module.rawValue)
        guard wanted != layout || slots.isEmpty else { return }
        layout = wanted

        for slot in slots.values { NSStatusBar.system.removeStatusItem(slot.item) }
        slots.removeAll()

        if shown.isEmpty {
            addSlot(key: Self.fallbackKey, module: nil)
        } else if settings.stored.combined {
            addSlot(key: Self.combinedKey, module: nil)
        } else {
            for config in shown.reversed() { addSlot(key: config.module.rawValue, module: config.module) }
        }
        scheduleFitCheck()
    }

    private func addSlot(key: String, module: Module?) {
        // A stored position would override our order, so it is cleared first.
        let autosaveName = "jmt.\(key)"
        UserDefaults.standard.removeObject(forKey: "NSStatusItem Preferred Position \(autosaveName)")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = autosaveName
        let slot = Slot(item: item)
        slots[key] = slot
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.identifier = NSUserInterfaceItemIdentifier(key)
        if key == Self.fallbackKey {
            item.length = NSStatusItem.squareLength
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "jMacosTweaker")
            return
        }
        slot.view.frame = button.bounds
        slot.view.autoresizingMask = [.width, .height]
        button.addSubview(slot.view)
        button.setAccessibilityLabel(module?.title ?? "jMacosTweaker")
    }

    private func entry(_ config: WidgetConfig, _ contents: [Module: WidgetContent]) -> WidgetView.Entry {
        let content = contents[config.module] ?? WidgetEvaluator.content(for: config, store: store, unit: settings.stored.temperatureUnit)
        return WidgetView.Entry(
            content: content,
            style: config.style,
            showsLabel: config.showsLabel,
            history: config.style == .sparkline ? WidgetEvaluator.recentHistory(config.module, store: store) : []
        )
    }

    private func update(_ enabled: [WidgetConfig], _ contents: [Module: WidgetContent]) {
        let accent = Tokens.menuBarAccent(settings.stored.accent)
        let shown = enabled.filter { visible.contains($0.module) }
        if settings.stored.combined, let slot = slots[Self.combinedKey] {
            apply(shown.map { entry($0, contents) }, to: slot, accent: accent)
        }
        for config in shown {
            if let slot = slots[config.module.rawValue] {
                apply([entry(config, contents)], to: slot, accent: accent)
                slot.item.button?.setAccessibilityValue(slot.view.entries.first?.content.value)
            }
        }
    }

    private func apply(_ entries: [WidgetView.Entry], to slot: Slot, accent: NSColor) {
        slot.view.accent = accent
        guard slot.view.entries != entries else { return }
        slot.view.entries = entries
        let width = slot.view.requiredWidth()
        if slot.item.length != width { slot.item.length = width }
    }

    /// macOS gives no callback when items do not fit, but their windows report as occluded.
    private func scheduleFitCheck() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.checkFit()
        }
    }

    private func checkFit() {
        onFitChanged?(Module.allCases.filter { module in
            guard let window = slots[module.rawValue]?.item.button?.window else { return false }
            return !window.occlusionState.contains(.visible)
        })
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            onContextMenu(sender)
            return
        }
        onOpen(sender.identifier.flatMap { Module(rawValue: $0.rawValue) }, sender)
    }
}
