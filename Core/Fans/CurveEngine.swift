import Foundation
import Shared

public enum CurveError: Error, Equatable, Sendable {
    case tooFewPoints
    case temperatureOutOfRange
    case percentOutOfRange
    case notIncreasing
    case notMonotonic
}

public enum CurveMath {
    public static let temperatureRange = 0.0...110.0

    /// A curve must rise with temperature: strictly in temperature, and never falling in percent.
    public static func validate(_ curve: FanCurve) -> Result<FanCurve, CurveError> {
        guard curve.points.count >= 2 else { return .failure(.tooFewPoints) }
        for point in curve.points {
            guard point.temperature.isFinite, temperatureRange.contains(point.temperature) else { return .failure(.temperatureOutOfRange) }
            guard point.percent.isFinite, (0...100).contains(point.percent) else { return .failure(.percentOutOfRange) }
        }
        for (a, b) in zip(curve.points, curve.points.dropFirst()) {
            guard b.temperature > a.temperature else { return .failure(.notIncreasing) }
            guard b.percent >= a.percent else { return .failure(.notMonotonic) }
        }
        return .success(curve)
    }

    /// Linear interpolation, flat beyond both ends.
    public static func percent(at temperature: Double, curve: FanCurve) -> Double {
        guard let first = curve.points.first, let last = curve.points.last else { return 100 }
        if temperature <= first.temperature { return first.percent }
        if temperature >= last.temperature { return last.percent }
        for (a, b) in zip(curve.points, curve.points.dropFirst()) where temperature <= b.temperature {
            let span = b.temperature - a.temperature
            return a.percent + (b.percent - a.percent) * (temperature - a.temperature) / span
        }
        return last.percent
    }

    /// Maps a percent to RPM within the fan's reported limits, so a result outside them cannot be produced.
    public static func rpm(percent: Double, minimum: Double, maximum: Double) -> Double {
        let clamped = min(max(percent, 0), 100)
        return min(max(minimum + (maximum - minimum) * clamped / 100, minimum), maximum)
    }
}

/// Turns a stream of temperatures into a calm stream of RPM targets: no hunting, no pointless writes.
public struct FanRamp: Sendable {
    public struct Tuning: Sendable {
        /// Weight of a new temperature sample in the smoothed value.
        public var smoothing = 0.3
        /// Temperature must move this far against the last direction before the target follows.
        public var hysteresis = 2.0
        public var rampUpPerSecond = 600.0
        public var rampDownPerSecond = 150.0
        /// Minimum time between changes of direction.
        public var dwell: TimeInterval = 10
        /// Smaller changes are not written.
        public var writeThreshold = 50.0

        public init() {}
    }

    public let tuning: Tuning
    private var smoothed: Double?
    private var settledTemperature: Double?
    private var current: Double?
    private var lastWritten: Double?
    private var lastTime: TimeInterval?
    private var lastDirectionChange: TimeInterval = -.infinity
    private var direction = 0.0

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// Returns a new RPM to write, or nil when nothing should be written.
    public mutating func step(temperature: Double, now: TimeInterval, target: (Double) -> Double) -> Double? {
        let value = smoothed.map { $0 + tuning.smoothing * (temperature - $0) } ?? temperature
        smoothed = value

        // Follows temperature in the rising direction at once, and in the falling direction only past the band.
        var effective = settledTemperature ?? value
        if value > effective || value < effective - tuning.hysteresis { effective = value }
        settledTemperature = effective

        let desired = target(effective)
        guard let previous = current, let last = lastTime else {
            current = desired
            lastTime = now
            lastWritten = desired
            return desired
        }
        let elapsed = max(now - last, 0)
        lastTime = now

        let wanted = desired - previous
        let wantedDirection = wanted > 0 ? 1.0 : wanted < 0 ? -1.0 : 0
        if wantedDirection != 0, wantedDirection != direction {
            // A rise is always allowed, because cooling is the safe direction. Only a fall has to wait out the dwell.
            if wantedDirection < 0, direction > 0, now - lastDirectionChange < tuning.dwell { return nil }
            direction = wantedDirection
            lastDirectionChange = now
        }
        let limit = (wanted > 0 ? tuning.rampUpPerSecond : tuning.rampDownPerSecond) * elapsed
        let next = previous + min(max(wanted, -limit), limit)
        current = next

        // Reaching the final target always writes, or small changes near the end would never land.
        let reachedTarget = next == desired && lastWritten != desired
        if let written = lastWritten, abs(next - written) < tuning.writeThreshold, !reachedTarget { return nil }
        lastWritten = next
        return next
    }

    public mutating func reset() {
        self = FanRamp(tuning: tuning)
    }
}

public enum FanPreset: String, Codable, CaseIterable, Sendable {
    case system, silent, balanced, performance, maximum, constant, custom

    /// Built-in curves are conservative: all reach full speed by 90 °C, below the supervisor's 95 °C.
    public var curve: FanCurve? {
        switch self {
        case .silent:
            FanCurve(points: [.init(temperature: 50, percent: 0), .init(temperature: 70, percent: 15), .init(temperature: 80, percent: 45), .init(temperature: 90, percent: 100)])
        case .balanced:
            FanCurve(points: [.init(temperature: 45, percent: 0), .init(temperature: 60, percent: 20), .init(temperature: 75, percent: 55), .init(temperature: 88, percent: 100)])
        case .performance:
            FanCurve(points: [.init(temperature: 40, percent: 15), .init(temperature: 55, percent: 40), .init(temperature: 70, percent: 75), .init(temperature: 82, percent: 100)])
        default:
            nil
        }
    }
}

/// A saved preset, in the versioned import/export format.
public struct NamedPreset: Codable, Hashable, Sendable {
    public var name: String
    public var curve: FanCurve
    public var sensor: ControlSensor

    public init(name: String, curve: FanCurve, sensor: ControlSensor) {
        self.name = name
        self.curve = curve
        self.sensor = sensor
    }
}

public enum PresetFile {
    public static let currentSchema = 2

    public enum LoadError: Error, Equatable {
        case malformed
        case newerSchema(Int)
        case invalidCurve(String)
    }

    private struct Envelope: Decodable { var schema: Int }
    private struct Current: Codable { var schema: Int; var presets: [NamedPreset] }

    /// Schema 1 stored bare curves with no control sensor.
    private struct V1: Decodable {
        struct Item: Decodable { var name: String; var points: [CurvePoint] }
        var presets: [Item]
    }

    public static func encode(_ presets: [NamedPreset]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Current(schema: currentSchema, presets: presets))
    }

    /// Reads any known schema and migrates it. Never accepts a curve that fails validation.
    public static func decode(_ data: Data) -> Result<[NamedPreset], LoadError> {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return .failure(.malformed) }
        let presets: [NamedPreset]
        switch envelope.schema {
        case 1:
            guard let old = try? decoder.decode(V1.self, from: data) else { return .failure(.malformed) }
            presets = old.presets.map { NamedPreset(name: $0.name, curve: FanCurve(points: $0.points), sensor: .hottest) }
        case currentSchema:
            guard let current = try? decoder.decode(Current.self, from: data) else { return .failure(.malformed) }
            presets = current.presets
        case let other where other > currentSchema:
            return .failure(.newerSchema(other))
        default:
            return .failure(.malformed)
        }
        for preset in presets {
            if case .failure = CurveMath.validate(preset.curve) { return .failure(.invalidCurve(preset.name)) }
        }
        return .success(presets)
    }
}
