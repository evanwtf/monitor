import Darwin
import Foundation

/// Thin wrappers over `sysctlbyname`.
///
/// Two calls, both of the same shape: ask for the size, then ask for the
/// value. They live here rather than on one source because the machine
/// description below reads the same table the CPU source does.
public enum Sysctl {
    public static func int(_ name: String) -> Int? {
        var value = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    public static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // sysctl includes the null terminator in the byte count it reports.
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

/// What this Mac is.
///
/// The About panel says which machine the readings come from. A screenshot of
/// a dashboard is worth much less when nobody can tell whether it is an M4 or
/// a 2019 Intel, and the answer costs three sysctl calls.
///
/// Every field is optional at the source and falls back rather than throws:
/// nothing here is a measurement, so a missing key should cost a line of the
/// panel and nothing more.
public struct MachineInfo: Sendable {
    /// Marketing-ish model identifier, for example `Mac16,10`.
    public let model: String
    /// The CPU brand string: "Apple M4" on Apple silicon, the full Intel part
    /// number otherwise.
    public let chip: String
    public let cores: Int
    public let memoryBytes: Int
    /// For example `14.5.0`.
    public let systemVersion: String

    public static var current: MachineInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return MachineInfo(
            model: Sysctl.string("hw.model") ?? "Mac",
            chip: Sysctl.string("machdep.cpu.brand_string") ?? "unknown CPU",
            cores: ProcessInfo.processInfo.activeProcessorCount,
            memoryBytes: Sysctl.int("hw.memsize") ?? 0,
            systemVersion: "\(version.majorVersion).\(version.minorVersion)"
                + ".\(version.patchVersion)"
        )
    }

    /// One line for the About panel: chip, core count, memory.
    public var hardwareSummary: String {
        let gigabytes = Double(memoryBytes) / 1_073_741_824
        let memory = memoryBytes > 0 ? ", \(Int(gigabytes.rounded())) GB" : ""
        return "\(chip), \(cores) cores\(memory)"
    }
}
