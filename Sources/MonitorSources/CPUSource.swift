import Darwin
import Foundation
import MonitorCore

/// Aggregate and per-cluster CPU load, from `host_processor_info`.
///
/// The kernel reports cumulative ticks per core in four states, so load is the
/// difference between two readings — the first `read` therefore produces
/// nothing but a baseline. That is why the sampler must not treat an empty
/// batch as an error.
///
/// Apple silicon has clusters of cores with different ceilings, and load is
/// reported as one series per cluster. Averaging *across* clusters would be
/// meaningless — a pinned efficiency core and a pinned performance core are not
/// the same amount of work — but averaging *within* one is exactly right, since
/// a cluster's cores are interchangeable to the scheduler. A line per core says
/// less: at ten cores the chart is unreadable and its legend does not fit.
public final class CPUSource: MetricSource, @unchecked Sendable {
    public let id = "cpu"

    /// Ticks from the previous reading, one entry per core.
    private var previous: [ProcessorTicks] = []
    /// Resolved once: the topology cannot change while the process runs.
    private let clusters = CPUSource.readClusters()

    struct ProcessorTicks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32

        var total: UInt32 { user &+ system &+ idle &+ nice }
    }

    public init() {}

    public static let total = MetricID("cpu.total")
    public static let user = MetricID("cpu.user")
    public static let system = MetricID("cpu.system")

    /// Keyed by performance level, not by the cluster's marketing name.
    ///
    /// `hw.perflevel0` is always the fastest cluster on any machine that has
    /// them, so the id means the same thing everywhere and stays stable. The
    /// name does not: this M4 calls level 0 "Super" where earlier silicon calls
    /// it "Performance", and a `cpu.cluster.performance` id would have to be
    /// either a lie or a rename.
    public static func cluster(_ level: Int) -> MetricID { MetricID("cpu.perflevel.\(level)") }

    public var descriptors: [MetricDescriptor] {
        var result = [
            MetricDescriptor(
                id: Self.total, name: "Total", group: "CPU", unit: .fraction,
                nominalMaximum: 1
            ),
            MetricDescriptor(
                id: Self.user, name: "User", group: "CPU", unit: .fraction, nominalMaximum: 1
            ),
            MetricDescriptor(
                id: Self.system, name: "System", group: "CPU", unit: .fraction,
                nominalMaximum: 1
            ),
        ]
        for cluster in clusters {
            result.append(
                MetricDescriptor(
                    id: Self.cluster(cluster.level), name: cluster.name, group: "CPU Cores",
                    unit: .fraction, nominalMaximum: 1
                )
            )
        }
        return result
    }

    /// One cluster of interchangeable cores.
    struct Cluster {
        /// `hw.perflevel` index: 0 is always the fastest cluster.
        let level: Int
        /// The kernel's own name for it — "Super", "Performance", "Efficiency".
        let name: String
        /// The core indices `host_processor_info` reports it under.
        let cores: Range<Int>
    }

    /// Maps `hw.perflevel*` onto the core indices the kernel reports.
    ///
    /// `host_processor_info` numbers cores in **reverse** performance-level
    /// order: the slowest cluster comes first. Verified on this M4 (10 cores,
    /// 4 at level 0 named "Super", 6 at level 1 named "Efficiency") by pinning
    /// four `userInteractive` threads, which the scheduler puts on the fast
    /// cluster: cores 6–9 went to 99% and cores 0–5 stayed idle.
    ///
    /// Returns empty on a machine with fewer than two levels — an Intel Mac has
    /// one uniform cluster, and a single "cluster" series would just duplicate
    /// `cpu.total`. Also returns empty if the level sizes do not add up to the
    /// core count, because a wrong split is worse than no split: it would label
    /// real load as coming from the wrong kind of core.
    static func readClusters() -> [Cluster] {
        let levels = Sysctl.int("hw.nperflevels") ?? 1
        guard levels > 1 else { return [] }

        var descending: [(level: Int, name: String, count: Int)] = []
        for level in 0..<levels {
            guard let count = Sysctl.int("hw.perflevel\(level).logicalcpu"), count > 0 else {
                return []
            }
            let name = Sysctl.string("hw.perflevel\(level).name") ?? "Level \(level)"
            descending.append((level, name, count))
        }

        let total = descending.reduce(0) { $0 + $1.count }
        guard total == ProcessInfo.processInfo.activeProcessorCount else { return [] }

        var result: [Cluster] = []
        var start = 0
        for entry in descending.reversed() {
            result.append(
                Cluster(
                    level: entry.level,
                    name: entry.name,
                    cores: start..<(start + entry.count)
                )
            )
            start += entry.count
        }
        // Fastest cluster first, so it takes the first series colour and reads
        // at the top of the legend.
        return result.sorted { $0.level < $1.level }
    }

    public func read(at timestamp: TimeInterval) throws -> SampleBatch {
        let current = try Self.readTicks()
        defer { previous = current }

        // First reading: baseline only. Two cumulative counters are needed
        // before a load exists at all.
        guard previous.count == current.count, !previous.isEmpty else {
            return SampleBatch(timestamp: timestamp, samples: [])
        }

        var values: [MetricID: Double] = [:]
        var userTicks = 0.0, systemTicks = 0.0, totalTicks = 0.0
        // Busy fraction per core, for the cluster averages below.
        var busy = [Double?](repeating: nil, count: current.count)

        for (index, now) in current.enumerated() {
            let before = previous[index]
            let elapsed = Double(now.total &- before.total)
            guard elapsed > 0 else { continue }

            let user = Double(now.user &- before.user) + Double(now.nice &- before.nice)
            let system = Double(now.system &- before.system)
            let idle = Double(now.idle &- before.idle)

            busy[index] = (elapsed - idle) / elapsed
            userTicks += user
            systemTicks += system
            totalTicks += elapsed
        }

        // The mean over a cluster's cores. Cores that reported no elapsed ticks
        // are left out of both halves of the average rather than counted as
        // idle: a core the kernel did not advance this tick has no load to
        // report, and calling that zero would drag the cluster down.
        for cluster in clusters {
            let loads = cluster.cores.compactMap { $0 < busy.count ? busy[$0] : nil }
            guard !loads.isEmpty else { continue }
            values[Self.cluster(cluster.level)] = loads.reduce(0, +) / Double(loads.count)
        }

        if totalTicks > 0 {
            values[Self.user] = userTicks / totalTicks
            values[Self.system] = systemTicks / totalTicks
            values[Self.total] = (userTicks + systemTicks) / totalTicks
        }
        return SampleBatch(timestamp: timestamp, values: values)
    }

    /// One `host_processor_info` call, unpacked into per-core tick counts.
    static func readTicks() throws -> [ProcessorTicks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount
        )
        guard result == KERN_SUCCESS, let info else {
            throw MetricSourceError.readFailed("processor load", code: result)
        }
        // host_processor_info allocates in the task's VM; the caller owns it.
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        return (0..<Int(count)).map { core in
            let base = core * Int(CPU_STATE_MAX)
            return ProcessorTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            )
        }
    }
}
