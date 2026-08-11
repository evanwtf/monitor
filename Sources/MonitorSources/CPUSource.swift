import Darwin
import Foundation
import MonitorCore

/// Per-core and aggregate CPU load, from `host_processor_info`.
///
/// The kernel reports cumulative ticks per core in four states, so load is the
/// difference between two readings — the first `read` therefore produces
/// nothing but a baseline. That is why the sampler must not treat an empty
/// batch as an error.
///
/// Apple silicon has efficiency and performance cores with different ceilings.
/// This source reports every core separately and lets the UI group them; it
/// does not try to average a P-core and an E-core into one number, because that
/// number would not mean anything.
public final class CPUSource: MetricSource, @unchecked Sendable {
    public let id = "cpu"

    /// Ticks from the previous reading, one entry per core.
    private var previous: [ProcessorTicks] = []

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
    public static func core(_ index: Int) -> MetricID { MetricID("cpu.core.\(index)") }

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
        for index in 0..<ProcessInfo.processInfo.activeProcessorCount {
            result.append(
                MetricDescriptor(
                    id: Self.core(index), name: "Core \(index)", group: "CPU Cores",
                    unit: .fraction, nominalMaximum: 1
                )
            )
        }
        return result
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

        for (index, now) in current.enumerated() {
            let before = previous[index]
            let elapsed = Double(now.total &- before.total)
            guard elapsed > 0 else { continue }

            let user = Double(now.user &- before.user) + Double(now.nice &- before.nice)
            let system = Double(now.system &- before.system)
            let idle = Double(now.idle &- before.idle)

            values[Self.core(index)] = (elapsed - idle) / elapsed
            userTicks += user
            systemTicks += system
            totalTicks += elapsed
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
