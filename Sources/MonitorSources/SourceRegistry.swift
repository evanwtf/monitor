import Foundation
import MonitorCore

/// Every source the app knows how to build.
///
/// One list, used by the app, the daemon and the CLI alike, so a source added
/// here appears in all three without further wiring.
public enum SourceRegistry {
    public static func makeAll() -> [any MetricSource] {
        [
            CPUSource(),
            MemorySource(),
            DiskSource(),
            NetworkSource(),
            GPUSource(),
            SMCSource(),
        ]
    }

    /// Build only the named sources. Used by `monitorctl --source` to isolate
    /// one reader while working on it.
    public static func make(ids: [String]) -> [any MetricSource] {
        let wanted = Set(ids)
        return makeAll().filter { wanted.contains($0.id) }
    }

    /// Every source's id.
    ///
    /// A `let`, not a computed property: it used to call `makeAll()` on every
    /// access, and `makeAll()` builds real readers — `SMCSource` opens an IOKit
    /// connection. Cheap when the app asks once at launch, and not cheap at all
    /// once `monitorctl` put this list in a `--help` string that ArgumentParser
    /// rebuilds on every parse. The ids never change within a process, so build
    /// them once and let the readers go.
    public static let allIDs: [String] = makeAll().map(\.id)

    /// Descriptors for every metric the app can produce, whether or not this
    /// machine can currently read it. The UI lays out from this.
    public static var allDescriptors: [MetricDescriptor] {
        makeAll().flatMap(\.descriptors)
    }
}
