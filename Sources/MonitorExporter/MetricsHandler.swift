import Foundation
import MonitorCore
import MonitorPrometheus

/// Reads the sensor sources once per scrape and renders the /metrics body.
///
/// Locked: a source such as SMCSource holds a single IOKit connection, and two
/// overlapping scrapes must not read it at the same time.
final class MetricsHandler: @unchecked Sendable {
    private let sources: [any MetricSource]
    private let lock = NSLock()

    init(sources: [any MetricSource]) {
        self.sources = sources
    }

    /// The full /metrics body for one scrape. A source that throws, or a metric
    /// that does not map, contributes nothing — gap, never zero.
    func exposition(now: TimeInterval = Date().timeIntervalSince1970) -> String {
        lock.lock()
        defer { lock.unlock() }

        var entries: [(MappedMetric, Double)] = []
        for source in sources {
            guard let batch = try? source.read(at: now) else { continue }
            for sample in batch.samples {
                guard let mapped = PrometheusMapping.map(sample.metric) else { continue }
                entries.append((mapped, sample.value))
            }
        }
        var families = PrometheusFamilyBuilder.families(from: entries)
        families.append(Self.buildInfo)
        return renderExposition(families)
    }

    /// A constant series carrying the build, so a scrape says which binary answered.
    static let buildInfo = PrometheusFamily(
        name: "monitor_exporter_build_info",
        help: "Build information; the value is always 1.",
        samples: [PrometheusSample(
            labels: [
                PrometheusLabel(name: "version", value: MonitorVersion.string),
                PrometheusLabel(name: "commit", value: BuildStamp.commit),
            ],
            value: 1
        )]
    )
}
