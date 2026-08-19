import Darwin
import Foundation
import MonitorCore

/// Memory use and pressure, from `host_statistics64` and `sysctl`.
///
/// "Used" here follows Activity Monitor's definition rather than the raw page
/// counts: app memory plus wired plus compressed. Inactive and purgeable pages
/// are not counted as used, because macOS reclaims them on demand and counting
/// them makes a healthy machine look full.
public final class MemorySource: MetricSource, @unchecked Sendable {
    public let id = "memory"

    public static let used = MetricID("memory.used")
    public static let app = MetricID("memory.app")
    public static let wired = MetricID("memory.wired")
    public static let compressed = MetricID("memory.compressed")
    public static let cached = MetricID("memory.cached")
    public static let free = MetricID("memory.free")
    public static let swapUsed = MetricID("memory.swap.used")
    /// Page-ins and page-outs per second, derived from cumulative counters.
    public static let pageIn = MetricID("memory.pagein.rate")
    public static let pageOut = MetricID("memory.pageout.rate")

    /// Physical RAM. Read once — it does not change while the app runs.
    public let physicalMemory = ProcessInfo.processInfo.physicalMemory

    private var rates = RateTracker()

    public init() {}

    public var descriptors: [MetricDescriptor] {
        let ceiling = Double(physicalMemory)
        return [
            MetricDescriptor(
                id: Self.used, name: "Used", group: "Memory", unit: .bytes,
                nominalMaximum: ceiling
            ),
            MetricDescriptor(
                id: Self.app, name: "App", group: "Memory", unit: .bytes,
                nominalMaximum: ceiling
            ),
            MetricDescriptor(
                id: Self.wired, name: "Wired", group: "Memory", unit: .bytes,
                nominalMaximum: ceiling
            ),
            MetricDescriptor(
                id: Self.compressed, name: "Compressed", group: "Memory", unit: .bytes,
                nominalMaximum: ceiling
            ),
            MetricDescriptor(
                id: Self.cached, name: "Cached", group: "Memory", unit: .bytes,
                nominalMaximum: ceiling
            ),
            MetricDescriptor(
                id: Self.free, name: "Free", group: "Memory", unit: .bytes,
                nominalMaximum: ceiling
            ),
            MetricDescriptor(id: Self.swapUsed, name: "Swap", group: "Memory", unit: .bytes),
            MetricDescriptor(
                id: Self.pageIn, name: "Page in", group: "Memory Paging",
                unit: .operationsPerSecond, direction: .inbound
            ),
            MetricDescriptor(
                id: Self.pageOut, name: "Page out", group: "Memory Paging",
                unit: .operationsPerSecond, direction: .outbound
            ),
        ]
    }

    public func read(at timestamp: TimeInterval) throws -> SampleBatch {
        let stats = try Self.readVMStatistics()
        // `sysconf` rather than the `vm_kernel_page_size` global: the global is
        // an imported `var`, which Swift 6 rejects as shared mutable state.
        let pageSize = Double(sysconf(_SC_PAGESIZE))

        let wired = Double(stats.wire_count) * pageSize
        let active = Double(stats.active_count) * pageSize
        let inactive = Double(stats.inactive_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        let purgeable = Double(stats.purgeable_count) * pageSize
        let external = Double(stats.external_page_count) * pageSize
        let free = Double(stats.free_count) * pageSize

        // App memory: anonymous pages that are not file-backed and not
        // purgeable — what a process would actually have to swap out.
        let app = max(0, active + inactive - purgeable - external)

        var values: [MetricID: Double] = [
            Self.wired: wired,
            Self.app: app,
            Self.compressed: compressed,
            Self.cached: external + purgeable,
            Self.free: free,
            Self.used: app + wired + compressed,
        ]

        if let swap = Self.readSwapUsage() {
            values[Self.swapUsed] = Double(swap.xsu_used)
        }

        let ins = Double(stats.pageins)
        let outs = Double(stats.pageouts)
        if let rate = rates.rate(for: Self.pageIn, total: ins, at: timestamp) {
            values[Self.pageIn] = rate
        }
        if let rate = rates.rate(for: Self.pageOut, total: outs, at: timestamp) {
            values[Self.pageOut] = rate
        }

        return SampleBatch(timestamp: timestamp, values: values)
    }

    static func readVMStatistics() throws -> vm_statistics64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw MetricSourceError.readFailed("vm statistics", code: result)
        }
        return stats
    }

    static func readSwapUsage() -> xsw_usage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        var name: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        guard sysctl(&name, 2, &usage, &size, nil, 0) == 0 else { return nil }
        return usage
    }
}
