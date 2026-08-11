import Foundation
import MonitorCore
@testable import MonitorSources
import Testing

/// These run against the real machine, because there is nothing to mock: the
/// whole job of a source is to read this Mac correctly. They assert the shape
/// and the plausible range of a reading rather than a value, which is what can
/// be checked on a machine doing unknown work.
@Suite("Sources")
struct SourceTests {
    @Test("every source declares metrics with unique ids")
    func uniqueIDs() {
        let all = SourceRegistry.allDescriptors.map(\.id)
        #expect(all.count == Set(all).count, "two metrics share an id; history would collide")
    }

    @Test("CPU load is a fraction, and the first read is only a baseline")
    func cpu() throws {
        let source = CPUSource()
        let first = try source.read(at: 0)
        #expect(first.samples.isEmpty, "a single tick counter reading cannot yield a load")

        Thread.sleep(forTimeInterval: 0.2)
        let second = try source.read(at: 0.2)
        #expect(!second.samples.isEmpty)
        for sample in second.samples {
            #expect(sample.value >= 0 && sample.value <= 1, "\(sample.metric) out of range")
        }
    }

    @Test("memory readings are positive and bounded by physical RAM")
    func memory() throws {
        let source = MemorySource()
        let batch = try source.read(at: 0)
        let used = batch.samples.first { $0.metric == MemorySource.used }
        let value = try #require(used?.value)
        #expect(value > 0)
        #expect(value <= Double(source.physicalMemory))
    }

    @Test("disk counters differentiate into non-negative rates")
    func disk() throws {
        let source = DiskSource()
        _ = try source.read(at: 0)
        Thread.sleep(forTimeInterval: 0.2)
        for sample in try source.read(at: 0.2).samples {
            #expect(sample.value >= 0, "\(sample.metric) went negative")
        }
    }

    @Test("network counters differentiate into non-negative rates")
    func network() throws {
        let source = NetworkSource()
        _ = try source.read(at: 0)
        Thread.sleep(forTimeInterval: 0.2)
        for sample in try source.read(at: 0.2).samples {
            #expect(sample.value >= 0, "\(sample.metric) went negative")
        }
    }

    /// The GPU source reads undocumented IOKit keys, so it is allowed to be
    /// unavailable. What it is not allowed to do is invent a number.
    @Test("GPU either reads a plausible value or reports unavailable")
    func gpu() {
        let source = GPUSource()
        do {
            let batch = try source.read(at: 0)
            for sample in batch.samples where sample.metric == GPUSource.utilization {
                #expect(sample.value >= 0 && sample.value <= 1)
            }
        } catch let error as MetricSourceError {
            if case .unavailable = error { return }
            Issue.record("unexpected error: \(error)")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("one failing source does not stop the others")
    func samplerIsolatesFailures() async {
        struct Broken: MetricSource {
            let id = "broken"
            var descriptors: [MetricDescriptor] { [] }
            func read(at _: TimeInterval) throws -> SampleBatch {
                throw MetricSourceError.unavailable("nothing")
            }
        }
        let sampler = Sampler(sources: [Broken(), MemorySource()], sinks: [])
        let batch = await sampler.tick(at: 1)
        #expect(!batch.samples.isEmpty, "a broken source suppressed a working one")
    }
}
