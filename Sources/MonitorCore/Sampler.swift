import Foundation

/// Where samples go after they are read.
public protocol SampleSink: Sendable {
    func receive(_ batch: SampleBatch) async
}

/// Drives every source on one clock.
///
/// All sources are read on the same tick so their samples share a timestamp and
/// line up on the x-axis. A source that throws is logged and skipped for that
/// tick — one broken reader must not stop the rest.
///
/// A source may be read on only *some* ticks — sensors refresh once a second,
/// so reading them at 2 Hz costs an IOKit round trip to be told the same number
/// again. That is still one clock: a slow source is sampled on every nth tick
/// of the same clock, not on a second timer. Its samples therefore land on
/// exactly the same timestamps as everything else, which is what stops two
/// series drifting apart on the x-axis.
public actor Sampler {
    public private(set) var interval: TimeInterval
    private let sources: [any MetricSource]
    private let sinks: [any SampleSink]
    private var task: Task<Void, Never>?
    /// Sources that failed, with how many ticks in a row. Used to stop logging
    /// the same failure sixty times a minute.
    private var failures: [String: Int] = [:]

    public init(
        sources: [any MetricSource],
        sinks: [any SampleSink],
        interval: TimeInterval = 1.0
    ) {
        self.sources = sources
        self.sinks = sinks
        self.interval = interval
    }

    public var descriptors: [MetricDescriptor] {
        sources.flatMap(\.descriptors)
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await tick()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Change the sampling rate. The running loop picks it up on its next pass.
    public func setInterval(_ newValue: TimeInterval) {
        interval = max(0.1, newValue)
    }

    /// Read every source once and forward the result. Public so `monitorctl`
    /// and the tests can drive sampling without a clock.
    ///
    /// `skipping` names sources to leave alone this tick, by `id`. A skipped
    /// source contributes no samples, which is not the same as failing: the UI
    /// keeps the last value and draws nothing new, rather than greying the card
    /// out.
    @discardableResult
    public func tick(
        at timestamp: TimeInterval = Date().timeIntervalSince1970,
        skipping: Set<String> = []
    ) async -> SampleBatch {
        var samples: [Sample] = []
        for source in sources where !skipping.contains(source.id) {
            do {
                let batch = try source.read(at: timestamp)
                samples.append(contentsOf: batch.samples)
                failures[source.id] = nil
            } catch {
                let seen = (failures[source.id] ?? 0) + 1
                failures[source.id] = seen
                // First failure and then every hundredth. A source that is
                // simply unavailable on this machine fails on every tick, and
                // that is not news after the first line.
                if seen == 1 || seen % 100 == 0 {
                    log.error("source \(source.id) failed: \(error) (\(seen)x)")
                }
            }
        }
        let batch = SampleBatch(timestamp: timestamp, samples: samples)
        for sink in sinks {
            await sink.receive(batch)
        }
        return batch
    }
}
