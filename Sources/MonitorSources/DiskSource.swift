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
                id: Self.readLatency, name: "Read latency", group: "Disk Latency",
                unit: .seconds
            ),
            MetricDescriptor(
                id: Self.writeLatency, name: "Write latency", group: "Disk Latency",
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
        let readTimeRate = rates.rate(
            for: Self.readLatency,
            total: totals.readTime,
            at: timestamp
        )
        let writeTimeRate = rates.rate(
            for: Self.writeLatency, total: totals.writeTime, at: timestamp
        )
        if let readTimeRate, let reads = values[Self.readsPerSecond], reads > 0 {
            values[Self.readLatency] = readTimeRate / reads / 1_000_000_000
        }
        if let writeTimeRate, let writes = values[Self.writesPerSecond], writes > 0 {
            values[Self.writeLatency] = writeTimeRate / writes / 1_000_000_000
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
