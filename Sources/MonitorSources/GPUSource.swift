import Foundation
import IOKit
import MonitorCore

/// GPU utilization and VRAM, from the accelerator's IOKit performance
/// statistics.
///
/// This is the least solid source in the app, and it is worth being honest
/// about why. Apple publishes no supported API for GPU utilization. There are
/// three routes and each has a real cost:
///
///  1. `IOAccelerator` performance statistics — what this reads. No privileges
///     needed, works on Apple silicon and Intel, but the dictionary keys are
///     undocumented and have changed across macOS releases. So every key is
///     looked up from a candidate list and a miss degrades to "unavailable"
///     rather than to a wrong number.
///  2. `powermetrics` — accurate and includes GPU power, but needs root, which
///     would mean a privileged helper for a monitoring app.
///  3. IOReport — what powermetrics itself uses. Private, and using it would
///     rule out the App Store.
///
/// Route 1 is the right default. If the keys are missing the app shows the
/// card as unavailable, which is much better than a plausible fabricated line.
public final class GPUSource: MetricSource, @unchecked Sendable {
    public let id = "gpu"

    public static let utilization = MetricID("gpu.utilization")
    public static let vramUsed = MetricID("gpu.vram.used")

    /// Undocumented and version-dependent, so each is a list of spellings seen
    /// in the wild. First hit wins.
    private static let utilizationKeys = ["Device Utilization %", "GPU Core Utilization"]
    private static let vramKeys = ["In use system memory", "vramUsedBytes"]

    public init() {}

    public var descriptors: [MetricDescriptor] {
        [
            MetricDescriptor(
                id: Self.utilization, name: "GPU", group: "GPU", unit: .fraction,
                nominalMaximum: 1
            ),
            MetricDescriptor(id: Self.vramUsed, name: "VRAM", group: "GPU", unit: .bytes),
        ]
    }

    public func read(at timestamp: TimeInterval) throws -> SampleBatch {
        var iterator = io_iterator_t()
        let matching = IOServiceMatching("IOAccelerator")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            throw MetricSourceError.readFailed("accelerators", code: result)
        }
        defer { IOObjectRelease(iterator) }

        var values: [MetricID: Double] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard
                IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
                == KERN_SUCCESS,
                let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                let statistics = properties["PerformanceStatistics"] as? [String: Any]
            else { continue }

            if let percent = Self.firstNumber(in: statistics, keys: Self.utilizationKeys) {
                // Take the busiest accelerator rather than a mean. On a machine
                // with two GPUs, one pinned and one idle is not "half loaded".
                values[Self.utilization] = max(values[Self.utilization] ?? 0, percent / 100)
            }
            if let bytes = Self.firstNumber(in: statistics, keys: Self.vramKeys) {
                values[Self.vramUsed] = (values[Self.vramUsed] ?? 0) + bytes
            }
        }

        guard !values.isEmpty else {
            throw MetricSourceError.unavailable("GPU performance statistics")
        }
        return SampleBatch(timestamp: timestamp, values: values)
    }

    static func firstNumber(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let number = dictionary[key] as? NSNumber { return number.doubleValue }
        }
        return nil
    }
}
