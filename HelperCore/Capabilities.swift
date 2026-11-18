import Core
import Foundation
import Shared

/// Decides whether control may run on this Mac. Invariant 10: an unexpected probe result disables the feature.
public enum CapabilityProbe {
    /// Model and OS major versions where each feature has passed an on-device test.
    /// The root-owned flag file exists only for a deliberate test on anything else.
    public struct Verified: Sendable {
        public var fanControl: [(model: String, osMajor: Int)] = []
        public var chargeControl: [(model: String, osMajor: Int)] = []
        public init() {}
    }

    /// Mac16,8 fans, on macOS 27.2: Constant and curves on both fans, gradual speed changes, and hand-back when the app
    /// quits or is replaced, all observed through recorded keys.
    ///
    /// Mac16,8 charge, on macOS 27.2: `CHIE` = 1 sets the adapter aside within about 3 s, so the Mac runs from its
    /// battery, and 0 brings the adapter back within seconds (approved clean run, 2026-11-01; see SAFETY.md).
    /// That is a pause that drains the battery, not a hold, so the app offers it only as Pause Charging and keeps the
    /// limit with the macOS setting.
    public static let verified: Verified = {
        var list = Verified()
        list.fanControl = [("Mac16,8", 27)]
        list.chargeControl = [("Mac16,8", 27)]
        return list
    }()

    public static func fans(
        port: any SMCPort, fanCount: Int, model: String, osMajor: Int, allowUnverified: Bool, verified: Verified = verified
    ) -> Capability {
        guard fanCount > 0 else { return .unavailable("This Mac has no fans.") }
        for fan in 0..<fanCount {
            guard let mode = port.info(FanKeys.mode(fan)), mode.size == 1, mode.hasWriteHint,
                  let target = port.info(FanKeys.target(fan)), target.hasWriteHint,
                  target.type == "flt " || target.type == "fpe2" else {
                return .unavailable("Fan keys on this Mac do not match what was expected, so fan control stays off.")
            }
        }
        let known = verified.fanControl.contains { $0.model == model && $0.osMajor == osMajor }
        guard known || allowUnverified else {
            return .unavailable("Fan control has not been verified on this Mac and macOS version yet.")
        }
        return .available
    }

    public static func charge(
        port: any SMCPort, hasBattery: Bool, model: String, osMajor: Int, allowUnverified: Bool, verified: Verified = verified
    ) -> Capability {
        guard hasBattery else { return .unavailable("This Mac has no battery.") }
        guard let info = port.info(KeyWhitelist.chargeInhibit), info.size == 1, info.hasWriteHint else {
            return .unavailable("No known charge control key exists on this Mac.")
        }
        let known = verified.chargeControl.contains { $0.model == model && $0.osMajor == osMajor }
        guard known || allowUnverified else {
            return .unavailable("There is no verified way to limit charging through the helper on this Mac and macOS version.")
        }
        return .available
    }
}
