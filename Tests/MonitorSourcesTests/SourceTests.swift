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

    /// The conversion lives in the source so that the dial, the chart axis and
    /// `monitorctl` cannot disagree about whether a link is busy. If the
    /// descriptor ever says bytes again, every one of those reads eight times
    /// low without anything looking broken.
    @Test("network throughput is declared and reported in bits")
    func networkReportsBits() throws {
        let source = NetworkSource()
        let throughput = source.descriptors.filter { $0.group == "Network" }
        #expect(throughput.count == 2)
        #expect(throughput.allSatisfy { $0.unit == .bitsPerSecond })
        #expect(Set(throughput.map(\.id)) == [NetworkSource.bitsIn, NetworkSource.bitsOut])

        // Eight times the byte counter, read back from the same interfaces.
        let bytes = try NetworkSource.readInterfaceTotals()
        _ = try source.read(at: 0)
        Thread.sleep(forTimeInterval: 0.2)
        let batch = try source.read(at: 0.2)
        for sample in batch.samples where sample.metric == NetworkSource.bitsIn {
            // A rate, not a total, so this only bounds it: the machine cannot
            // have received more bits since the first read than it had bytes
            // times eight in total since boot.
            #expect(sample.value <= bytes.bytesIn * 8 + 1)
        }
    }

    /// Disk stays in bytes. Drives are quoted in bytes and networks in bits,
    /// and the two dials sitting side by side must not both say "10" while
    /// meaning different things.
    @Test("disk throughput stays in bytes")
    func diskReportsBytes() {
        let throughput = DiskSource().descriptors.filter { $0.group == "Disk" }
        #expect(throughput.count == 2)
        #expect(throughput.allSatisfy { $0.unit == .bytesPerSecond })
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
