import Foundation

public struct CurvePoint: Codable, Hashable, Sendable {
    public var temperature: Double
    /// 0 is the fan's hardware minimum and 100 its maximum.
    public var percent: Double

    public init(temperature: Double, percent: Double) {
        self.temperature = temperature
        self.percent = percent
    }
}

public struct FanCurve: Codable, Hashable, Sendable {
    public var points: [CurvePoint]

    public init(points: [CurvePoint]) {
        self.points = points
    }
}

public enum ControlSensor: Codable, Hashable, Sendable {
    case cpuAverage
    case cpuHottest
    case gpu
    case ssd
    case battery
    case hottest
    /// A chosen set of sensor IDs, combined by maximum or average.
    case custom(ids: [String], useAverage: Bool)
}

public enum FanPolicy: Codable, Hashable, Sendable {
    /// System control. The default, and every failure path's destination.
    case system
    case constant(percent: Double)
    case curve(FanCurve)
    case maximum
}

/// What the app asks for. Per fan, or the same for all when linked.
public struct FanRequest: Codable, Hashable, Sendable {
    public var policies: [Int: FanPolicy]
    public var sensor: ControlSensor

    public init(policies: [Int: FanPolicy], sensor: ControlSensor) {
        self.policies = policies
        self.sensor = sensor
    }
}

public struct ChargeRequest: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var limit: Int
    /// Charging resumes this many percent below the limit.
    public var sailing: Int
    public var heatProtection: Bool
    public var heatLimit: Double
    public var dischargeToLimit: Bool
    public var topUp: Bool

    public init(enabled: Bool, limit: Int, sailing: Int, heatProtection: Bool, heatLimit: Double, dischargeToLimit: Bool, topUp: Bool) {
        self.enabled = enabled
        self.limit = limit
        self.sailing = sailing
        self.heatProtection = heatProtection
        self.heatLimit = heatLimit
        self.dischargeToLimit = dischargeToLimit
        self.topUp = topUp
    }

    public static let off = ChargeRequest(enabled: false, limit: 80, sailing: 5, heatProtection: true, heatLimit: 40, dischargeToLimit: false, topUp: false)
}

public enum Capability: Codable, Hashable, Sendable {
    case available
    /// Read-only, with a reason the UI shows as written.
    case unavailable(String)

    public var isAvailable: Bool { self == .available }
}

public enum ChargeAction: String, Codable, Hashable, Sendable {
    case allowCharging
    case inhibitCharging
    case dischargeOnAdapter
}

public struct HelperStatus: Codable, Hashable, Sendable {
    public var protocolVersion: Int
    public var fanCapability: Capability
    public var chargeCapability: Capability
    public var fanRequest: FanRequest?
    public var chargeRequest: ChargeRequest
    public var chargeAction: ChargeAction
    public var fansUnderControl: [Int]
    public var targets: [Int: Double]
    public var supervisorReason: String?
    public var lastError: String?

    public init(
        protocolVersion: Int, fanCapability: Capability, chargeCapability: Capability, fanRequest: FanRequest?,
        chargeRequest: ChargeRequest, chargeAction: ChargeAction, fansUnderControl: [Int], targets: [Int: Double],
        supervisorReason: String?, lastError: String?
    ) {
        self.protocolVersion = protocolVersion
        self.fanCapability = fanCapability
        self.chargeCapability = chargeCapability
        self.fanRequest = fanRequest
        self.chargeRequest = chargeRequest
        self.chargeAction = chargeAction
        self.fansUnderControl = fansUnderControl
        self.targets = targets
        self.supervisorReason = supervisorReason
        self.lastError = lastError
    }
}

/// Reply to every call. `error` is a sentence the UI can show as written.
public struct HelperReply: Codable, Sendable {
    public var status: HelperStatus
    public var error: String?

    public init(status: HelperStatus, error: String?) {
        self.status = status
        self.error = error
    }
}

/// The whole privileged surface. There is deliberately no call that takes a key or raw bytes.
/// Payloads are JSON, decoded and validated in the helper.
@objc public protocol HelperXPC {
    func status(reply: @escaping @Sendable (Data?) -> Void)
    func applyFans(_ request: Data, reply: @escaping @Sendable (Data?) -> Void)
    func applyCharge(_ request: Data, reply: @escaping @Sendable (Data?) -> Void)
    func heartbeat()
    func restoreDefaults(reply: @escaping @Sendable (Data?) -> Void)
}

public enum HelperPaths {
    public static let binary = "/Library/PrivilegedHelperTools/com.jmacostweaker.helper"
    public static let launchDaemon = "/Library/LaunchDaemons/com.jmacostweaker.helper.plist"
    public static let supportDirectory = "/Library/Application Support/jMacosTweaker"
    public static let pinFile = supportDirectory + "/pinned-client.json"
    public static let journalFile = supportDirectory + "/restore-journal.json"
    public static let chargeFile = supportDirectory + "/charge-policy.json"
    public static let unverifiedFlagFile = supportDirectory + "/allow-unverified-control"
    public static let installedApp = "/Applications/jMacosTweaker.app"
}

public struct PinnedClient: Codable, Hashable, Sendable {
    public var cdhash: String
    public var path: String

    public init(cdhash: String, path: String) {
        self.cdhash = cdhash
        self.path = path
    }
}
