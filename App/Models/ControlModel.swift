import Core
import Foundation
import Observation
import Shared

/// Turns user choices into helper requests, and explains why a control is unavailable.
@MainActor
@Observable
final class ControlModel {
    let helper = HelperClient()
    private(set) var conflicts: [ToolConflict] = []
    /// The limit macOS is enforcing, the same setting as System Settings. It holds charge and runs from the adapter.
    private(set) var nativeChargeLimit: Int?
    private(set) var nativeChargeOptions: [Int] = []
    private(set) var nativeChargeError: String?
    private(set) var nativeChargeChecked = false

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let store: MonitorStore
    @ObservationIgnored private var lastExternal: Bool?
    @ObservationIgnored private var lastAutoSwitch: Bool?
    @ObservationIgnored private var pendingSpeed: Task<Void, Never>?
    @ObservationIgnored private var pendingCharge: Task<Void, Never>?
    @ObservationIgnored private var startWatch: Task<Void, Never>?
    /// Created only on Macs with a battery.
    @ObservationIgnored private lazy var nativeChargeClient: NativeChargeLimitClient? =
        store.availability.hasBattery ? NativeChargeLimitClient() : nil

    init(settings: AppSettings, store: MonitorStore) {
        self.settings = settings
        self.store = store
    }

    var settingsSnapshot: FanSettings { settings.stored.fan }
    var settingsChargeSnapshot: ChargeRequest { settings.stored.charge }

    func start() {
        Task {
            await refresh()
            // Fans never stay manual across an app restart unless asked again. The saved choice is re-sent here.
            if helper.state == .running, settings.stored.fan.preset != .system {
                await sendFans()
            }
        }
        settingsChanged()
    }

    func refresh() async {
        conflicts = await Task.detached { ConflictDetector.detect() }.value
        await refreshNativeCharge()
        await helper.refresh()
    }

    func settingsChanged() {
        let enabled = settings.stored.fan.switchByPowerSource
        guard enabled != lastAutoSwitch else { return }
        lastAutoSwitch = enabled
        let demand = enabled ? [SampleDemand(sources: [.battery], interval: 30)] : []
        let engine = store.engine
        Task { await engine.setDemands(owner: "fanAutoSwitch", demand) }
    }

    // MARK: Reasons

    /// Why fan control is read-only right now, or nil if it is usable.
    var fanBlockReason: String? {
        if let tool = ConflictDetector.blocker(in: conflicts, area: .fans) {
            return String(localized: "The background helper of \(tool.name) is running and can write the same fan settings, even with its app closed. Stop it to use fan control here: sudo launchctl bootout system/\(tool.label)")
        }
        return helperReason ?? capabilityReason(helper.status?.fanCapability)
    }

    var chargeBlockReason: String? {
        if let tool = ConflictDetector.blocker(in: conflicts, area: .charging) {
            return String(localized: "The background helper of \(tool.name) is running and can change charging, even with its app closed. Stop it to use the charge limit here: sudo launchctl bootout system/\(tool.label)")
        }
        return helperReason ?? capabilityReason(helper.status?.chargeCapability)
    }

    private func capabilityReason(_ capability: Capability?) -> String? {
        if case let .unavailable(reason) = capability { return reason }
        return nil
    }

    private var helperReason: String? {
        switch helper.state {
        case .checking: String(localized: "Checking the helper.")
        case .notInstalled: String(localized: "Control needs the privileged helper. Monitoring works without it.")
        case .needsRepin: String(localized: "This build is new, so the helper refuses it until you run the install script again.")
        case .notInstalledCopy: String(localized: "Open the copy in /Applications to use control.")
        case .outdated: String(localized: "The helper is outdated. Run the install script again.")
        case .notResponding: String(localized: "The helper is not responding.")
        case .running: nil
        }
    }

    /// Installed tools that are idle right now. Shown as a note only.
    var idleConflictNames: [String] {
        conflicts.filter { !$0.isRunning }.map(\.tool.name)
    }

    var installCommand: String {
        let resources = Bundle.main.resourcePath ?? ""
        return "sudo \"\(resources)/install_helper.sh\" \"\(Bundle.main.bundlePath)\""
    }

    /// For a deliberate on-device test on a Mac and macOS version that is not on the verified list.
    var testInstallCommand: String { installCommand + " --allow-unverified-control" }

    var isUnverifiedOnly: Bool {
        if case let .unavailable(reason) = helper.status?.fanCapability { return reason.contains("not been verified") }
        return false
    }

    var uninstallCommand: String {
        "sudo \"\(Bundle.main.resourcePath ?? "")/uninstall_helper.sh\""
    }

    // MARK: Fans

    func select(preset: FanPreset, fan: Int? = nil) {
        if let fan {
            settings.stored.fan.perFan[fan] = preset
            settings.stored.fan.linked = false
        } else {
            settings.stored.fan.preset = preset
        }
        Task { await sendFans() }
    }

    /// The slider fires many times while dragging, and only where it stops matters.
    func setConstant(percent: Double) {
        settings.stored.fan.constantPercent = min(max(percent, 0), 100)
        pendingSpeed?.cancel()
        pendingSpeed = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await sendFans()
        }
    }

    func setSensor(_ sensor: ControlSensor) {
        settings.stored.fan.sensor = sensor
        Task { await sendFans() }
    }

    func setLinked(_ linked: Bool) {
        settings.stored.fan.linked = linked
        Task { await sendFans() }
    }

    func setCustomCurve(_ curve: FanCurve) {
        guard case .success = CurveMath.validate(curve) else { return }
        settings.stored.fan.customCurve = curve
        settings.stored.fan.preset = .custom
        Task { await sendFans() }
    }

    func policy(for preset: FanPreset) -> FanPolicy {
        switch preset {
        case .system: .system
        case .maximum: .maximum
        case .constant: .constant(percent: settings.stored.fan.constantPercent)
        case .custom: .curve(settings.stored.fan.customCurve)
        case .silent, .balanced, .performance: preset.curve.map(FanPolicy.curve) ?? .system
        }
    }

    func buildFanRequest() -> FanRequest {
        let fan = settings.stored.fan
        var policies: [Int: FanPolicy] = [:]
        for index in 0..<store.availability.fanCount {
            policies[index] = policy(for: fan.linked ? fan.preset : fan.perFan[index] ?? .system)
        }
        return FanRequest(policies: policies, sensor: fan.sensor)
    }

    private func sendFans() async {
        guard fanBlockReason == nil else { return }
        await helper.applyFans(buildFanRequest())
        watchFanStart()
    }

    /// True in the seconds between asking for manual control and the hardware accepting it.
    var isStartingFans: Bool {
        guard helper.state == .running, let status = helper.status, status.lastError == nil,
              let request = status.fanRequest else { return false }
        return request.policies.values.contains { $0 != .system } && status.fansUnderControl.isEmpty
    }

    private func watchFanStart() {
        startWatch?.cancel()
        guard isStartingFans else { return }
        startWatch = Task {
            for _ in 0..<20 where !Task.isCancelled && isStartingFans {
                try? await Task.sleep(for: .seconds(1))
                await helper.refresh()
            }
        }
    }

    // MARK: Saved curves

    func saveCurve(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let fan = settings.stored.fan
        let curve = fan.preset == .custom ? fan.customCurve : fan.preset.curve ?? fan.customCurve
        settings.stored.fan.saved.removeAll { $0.name == trimmed }
        settings.stored.fan.saved.append(NamedPreset(name: trimmed, curve: curve, sensor: fan.sensor))
    }

    func renameCurve(_ old: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old else { return }
        settings.stored.fan.saved.removeAll { $0.name == trimmed }
        guard let index = settings.stored.fan.saved.firstIndex(where: { $0.name == old }) else { return }
        settings.stored.fan.saved[index].name = trimmed
    }

    func deleteCurve(_ name: String) {
        settings.stored.fan.saved.removeAll { $0.name == name }
    }

    func applySavedCurve(_ preset: NamedPreset) {
        settings.stored.fan.sensor = preset.sensor
        setCustomCurve(preset.curve)
    }

    /// Everything back to first-run values. The macOS charge limit is the user's own setting and stays.
    func resetAllSettings() {
        restoreDefaults()
        var fresh = AppSettings.Stored()
        fresh.hasCompletedOnboarding = true
        settings.stored = fresh
    }

    /// Follows the adapter when the option is on.
    func powerSourceChanged() {
        guard settings.stored.fan.switchByPowerSource, let external = store.battery.current?.externalConnected else { return }
        guard external != lastExternal else { return }
        lastExternal = external
        select(preset: external ? settings.stored.fan.presetOnAdapter : settings.stored.fan.presetOnBattery)
    }

    // MARK: Charge

    func updateCharge(_ change: (inout ChargeRequest) -> Void) {
        change(&settings.stored.charge)
        // The slider fires many times while dragging, and only where it stops matters.
        pendingCharge?.cancel()
        pendingCharge = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, chargeBlockReason == nil else { return }
            await helper.applyCharge(settings.stored.charge)
        }
    }

    // MARK: Native charge limit

    private func refreshNativeCharge() async {
        defer { nativeChargeChecked = true }
        guard let client = nativeChargeClient else { return }
        let state = await Task.detached { (client.availableLimits(), client.currentLimit()) }.value
        nativeChargeOptions = state.0
        nativeChargeLimit = state.1
    }

    func setNativeChargeLimit(_ value: Int) {
        guard let client = nativeChargeClient else { return }
        Task {
            let result = await Task.detached { NativeChargeLimit.apply(value, using: client) }.value
            if case .failure = result {
                nativeChargeError = String(localized: "macOS did not accept this limit. You can change it in System Settings, under Battery.")
            } else {
                nativeChargeError = nil
            }
            await refreshNativeCharge()
        }
    }

    // MARK: Restore

    func restoreDefaults() {
        settings.stored.fan.preset = .system
        settings.stored.fan.perFan = [:]
        settings.stored.charge = .off
        Task { await helper.restoreDefaults() }
    }

    // MARK: Status text

    func statusLine(base: String) -> String {
        var parts = [base]
        let fan = settings.stored.fan
        if helper.state == .running, fan.linked, fan.preset != .system {
            parts.append(String(localized: "Fans on \(fan.preset.title)"))
        }
        if helper.state == .running, settings.stored.charge.enabled {
            parts.append(String(localized: "Charge limit \(settings.stored.charge.limit)%"))
        } else if let limit = nativeChargeLimit, limit < 100 {
            parts.append(String(localized: "Charge limit \(limit)%"))
        }
        if let reason = helper.status?.supervisorReason {
            parts.append(String(localized: "Thermal protection active: \(reason)"))
        }
        return parts.joined(separator: ". ")
    }
}

extension FanPreset {
    var title: String {
        switch self {
        case .system: String(localized: "Auto")
        case .silent: String(localized: "Silent")
        case .balanced: String(localized: "Balanced")
        case .performance: String(localized: "Performance")
        case .maximum: String(localized: "Max")
        case .constant: String(localized: "Constant")
        case .custom: String(localized: "Custom")
        }
    }
}
