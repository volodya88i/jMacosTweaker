import Darwin
import Foundation

public struct KnownTool: Hashable, Sendable {
    public let name: String
    public let label: String
    public let controls: Set<ControlArea>

    public init(name: String, label: String, controls: Set<ControlArea>) {
        self.name = name
        self.label = label
        self.controls = controls
    }
}

public enum ControlArea: Hashable, Sendable {
    case fans
    case charging
}

public struct ToolConflict: Hashable, Sendable {
    public let tool: KnownTool
    public let isRunning: Bool

    public init(tool: KnownTool, isRunning: Bool) {
        self.tool = tool
        self.isRunning = isRunning
    }
}

/// Finds known third-party helpers by launchd label. Only labels observed on the development machine are listed, so
/// this is not a guarantee of detecting every tool. Read-back mismatches in the helper catch the rest.
public enum ConflictDetector {
    public static let knownTools = [
        KnownTool(name: "Macs Fan Control", label: "com.crystalidea.macsfancontrol.smcwrite", controls: [.fans]),
        KnownTool(name: "AlDente", label: "com.apphousekitchen.aldente-pro.helper", controls: [.charging])
    ]

    public static func detect(
        tools: [KnownTool] = knownTools,
        isInstalled: (String) -> Bool = { label in
            FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\(label).plist")
                || FileManager.default.fileExists(atPath: "/Library/PrivilegedHelperTools/\(label)")
        },
        isRunning: (String) -> Bool = processRunning
    ) -> [ToolConflict] {
        tools.compactMap { tool in
            let running = isRunning(tool.label)
            guard running || isInstalled(tool.label) else { return nil }
            return ToolConflict(tool: tool, isRunning: running)
        }
    }

    /// A running writer blocks control. An installed but idle helper is only a notice.
    public static func blocker(in conflicts: [ToolConflict], area: ControlArea) -> KnownTool? {
        conflicts.first { $0.isRunning && $0.tool.controls.contains(area) }?.tool
    }

    public static func processRunning(_ name: String) -> Bool {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        count = pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count) * Int32(MemoryLayout<pid_t>.stride)) }
        guard count > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(count)) {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            if String(decoding: buffer.prefix(Int(length)), as: UTF8.self).hasSuffix("/" + name) { return true }
        }
        return false
    }
}
