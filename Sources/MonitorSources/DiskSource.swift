import Foundation
import IOKit
import MonitorCore

/// Block-device throughput and operation counts, from the IOKit registry.
///
/// Every storage driver publishes `Statistics` under `IOBlockStorageDriver`
/// with cumulative bytes and operations since boot, which are differentiated
/// into rates. Counts are summed across devices; the skeleton does not yet
/// break them out per volume (see `docs/roadmap.md`).
///
/// Latency is the number that actually explains a stalled machine — throughput
/// can look idle while every read takes 40 ms. IOKit publishes total read and
/// write time, so mean latency is that divided by the operation count over the
/// same interval.
public final class DiskSource: MetricSource, @unchecked Sendable {
    public let id = "disk"

    public static let bytesRead = MetricID("disk.bytes.read")
    public static let bytesWritten = MetricID("disk.bytes.written")
    public static let readsPerSecond = MetricID("disk.ops.read")
    public static let writesPerSecond = MetricID("disk.ops.write")
    public static let readLatency = MetricID("disk.latency.read")
    public static let writeLatency = MetricID("disk.latency.write")

    private var rates = RateTracker()

    public init() {}

    public var descriptors: [MetricDescriptor] {
        [
            MetricDescriptor(
                id: Self.bytesRead, name: "Read", group: "Disk", unit: .bytesPerSecond
            ),
            MetricDescriptor(
                id: Self.bytesWritten, name: "Write", group: "Disk", unit: .bytesPerSecond
            ),
            MetricDescriptor(
                id: Self.readsPerSecond, name: "Reads", group: "Disk Ops",
                unit: .operationsPerSecond
            ),
            MetricDescriptor(
                id: Self.writesPerSecond, name: "Writes", group: "Disk Ops",
                unit: .operationsPerSecond
            ),
            MetricDescriptor(
                id: Self.readLatency, name: "Read", group: "Disk Latency",
                unit: .seconds
            ),
            MetricDescriptor(
                id: Self.writeLatency, name: "Write", group: "Disk Latency",
                unit: .seconds
            ),
        ]
    }

    /// Cumulative totals across every block device, in one pass of the registry.
    struct DiskTotals {
        var bytesRead = 0.0
        var bytesWritten = 0.0
        var reads = 0.0
        var writes = 0.0
        /// Nanoseconds spent in reads and writes, summed.
        var readTime = 0.0
        var writeTime = 0.0
    }

    public func read(at timestamp: TimeInterval) throws -> SampleBatch {
        let totals = try Self.readTotals()
        var values: [MetricID: Double] = [:]

        let counters: [(MetricID, Double)] = [
            (Self.bytesRead, totals.bytesRead),
            (Self.bytesWritten, totals.bytesWritten),
            (Self.readsPerSecond, totals.reads),
            (Self.writesPerSecond, totals.writes),
        ]
        for (metric, total) in counters {
            if let rate = rates.rate(for: metric, total: total, at: timestamp) {
                values[metric] = rate
            }
        }

        // Mean latency over the interval: time spent divided by operations
        // completed, both as deltas. Dividing the cumulative totals instead
        // would give the average since boot, which never moves.
        //
        // An interval with no operations reports **zero**, not nothing. With no
        // operations both deltas are zero, so there is no quotient to take and
        // zero is a choice rather than a computation — but it is the right one:
        // no time was spent waiting on the disk. Reporting nothing instead made
        // latency the only one of this source's six metrics that could go
        // absent on an idle tick, and the UI reads an absent metric as "not
        // available on this machine" — a claim about the hardware. That made the
        // card flap between its chart and that notice twice a second on an idle
        // machine (#5).
        //
        // The consequence, worth knowing: "completed instantly" and "nothing
        // happened" both draw as zero. The Disk Ops card beside it tells them
        // apart.
        let readTimeRate = rates.rate(
            for: Self.readLatency,
            total: totals.readTime,
            at: timestamp
        )
        let writeTimeRate = rates.rate(
            for: Self.writeLatency, total: totals.writeTime, at: timestamp
        )
        // Still nil on the very first tick, when the counters have no previous
        // reading — there is genuinely no rate yet, which is not the same thing
        // as an idle interval.
        if let readTimeRate, let reads = values[Self.readsPerSecond] {
            values[Self.readLatency] = reads > 0 ? readTimeRate / reads / 1_000_000_000 : 0
        }
        if let writeTimeRate, let writes = values[Self.writesPerSecond] {
            values[Self.writeLatency] = writes > 0 ? writeTimeRate / writes / 1_000_000_000 : 0
        }

        return SampleBatch(timestamp: timestamp, values: values)
    }

    /// The registry keys for the statistics dictionary.
    ///
    /// Spelled out as literals rather than using the `kIOBlockStorageDriver…`
    /// constants: those live in `IOKit/storage/IOBlockStorageDriver.h`, which
    /// is not in IOKit's Swift module map, so they do not exist in Swift. The
    /// strings themselves are stable and documented.
    enum StatisticsKey {
        static let dictionary = "Statistics"
        static let bytesRead = "Bytes (Read)"
        static let bytesWritten = "Bytes (Write)"
        static let reads = "Operations (Read)"
        static let writes = "Operations (Write)"
        static let readTime = "Total Time (Read)"
        static let writeTime = "Total Time (Write)"
    }

    static func readTotals() throws -> DiskTotals {
        var iterator = io_iterator_t()
        let matching = IOServiceMatching("IOBlockStorageDriver")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            throw MetricSourceError.readFailed("block storage drivers", code: result)
        }
        defer { IOObjectRelease(iterator) }

        var totals = DiskTotals()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard
                IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
                == KERN_SUCCESS,
                let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                let statistics = properties[StatisticsKey.dictionary] as? [String: Any]
            else { continue }

            func number(_ key: String) -> Double {
                (statistics[key] as? NSNumber)?.doubleValue ?? 0
            }
            totals.bytesRead += number(StatisticsKey.bytesRead)
            totals.bytesWritten += number(StatisticsKey.bytesWritten)
            totals.reads += number(StatisticsKey.reads)
            totals.writes += number(StatisticsKey.writes)
            totals.readTime += number(StatisticsKey.readTime)
            totals.writeTime += number(StatisticsKey.writeTime)
        }
        return totals
    }
}
