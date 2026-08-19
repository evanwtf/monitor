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

    @Test("a declared direction always has its opposite in the same group")
    func directionsComeInPairs() {
        // A group with an inbound metric and no outbound one can never mirror,
        // which is a declaration somebody half finished rather than a choice.
        // Checked against the real registry, which `MonitorCoreTests` cannot
        // see — it is the layer below this one.
        let directed = SourceRegistry.allDescriptors.filter { $0.direction != nil }
        #expect(!directed.isEmpty)
        for group in Set(directed.map(\.group)) {
            let members = directed.filter { $0.group == group }
            #expect(
                members.count(where: { $0.direction == .inbound }) == 1,
                "\(group) needs exactly one inbound metric"
            )
            #expect(
                members.count(where: { $0.direction == .outbound }) == 1,
                "\(group) needs exactly one outbound metric"
            )
            #expect(
                ChartMirror.pair(for: members) != nil,
                "\(group) declares directions but does not form a pair"
            )
        }
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

    /// A wrong split would label real load as coming from the wrong kind of
    /// core, which is worse than no split at all — so the source reports no
    /// clusters rather than guess. What it must never do is claim a topology
    /// that does not add up.
    @Test("CPU clusters cover every core exactly once, fastest first")
    func cpuClusters() {
        let clusters = CPUSource.readClusters()
        guard !clusters.isEmpty else { return } // uniform machine: no split
        let cores = ProcessInfo.processInfo.activeProcessorCount

        #expect(clusters.map(\.level) == clusters.map(\.level).sorted(), "not fastest first")
        #expect(Set(clusters.map(\.level)).count == clusters.count, "a level appeared twice")

        let covered = clusters.flatMap { Array($0.cores) }
        #expect(covered.count == cores, "clusters do not account for every core")
        #expect(Set(covered).count == cores, "a core belongs to two clusters")
        #expect(covered.allSatisfy { $0 >= 0 && $0 < cores })
        #expect(clusters.allSatisfy { !$0.name.isEmpty })
    }

    /// The cluster average must be an average, not a sum: a fully loaded
    /// cluster reads 100%, not 400%.
    @Test("cluster load stays a fraction")
    func cpuClusterRange() throws {
        let source = CPUSource()
        _ = try source.read(at: 0)
        Thread.sleep(forTimeInterval: 0.2)
        let batch = try source.read(at: 0.2)
        let levels = Set(CPUSource.readClusters().map { CPUSource.cluster($0.level) })
        for sample in batch.samples where levels.contains(sample.metric) {
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

    @Test("the memory slices account for the machine's RAM, and Used does not")
    func memoryPartsSumToTheWhole() throws {
        // The claim stacking rests on. If the slices overlapped, the stack
        // would climb past the top of the card, and if Used were one of them it
        // would count app, wired and compressed a second time.
        let source = MemorySource()
        let batch = try source.read(at: 0)
        let values = Dictionary(
            batch.samples.map { ($0.metric, $0.value) }, uniquingKeysWith: { first, _ in first }
        )
        let parts = source.descriptors
            .filter { $0.composition == .part }
            .compactMap { values[$0.id] }
        #expect(parts.count >= 2)

        let total = Double(source.physicalMemory)
        let summed = parts.reduce(0, +)
        // Not exact: macOS keeps page classes this does not name, so the slices
        // account for most of the RAM rather than all of it. What matters is
        // that they never exceed it, which overlapping slices would.
        #expect(summed <= total * 1.02, "the slices overlap; a stack would overflow")
        #expect(summed >= total * 0.85, "the slices leave too much unaccounted for")

        let used = try #require(values[MemorySource.used])
        #expect(used < summed, "Used is a sum of slices, not a slice")
    }

    @Test("CPU Total is exactly its slices")
    func cpuPartsSumToTotal() throws {
        let source = CPUSource()
        _ = try source.read(at: 0)
        Thread.sleep(forTimeInterval: 0.2)
        let samples = try source.read(at: 0.2).samples
        let values = Dictionary(
            samples.map { ($0.metric, $0.value) }, uniquingKeysWith: { first, _ in first }
        )
        let user = try #require(values[CPUSource.user])
        let system = try #require(values[CPUSource.system])
        let total = try #require(values[CPUSource.total])
        #expect(abs(user + system - total) < 0.0001)
    }

    @Test("a group that declares slices declares at least two of them")
    func slicesComeInTwos() {
        // One band is an area chart with extra steps, so a lone `.part` is a
        // declaration somebody half finished.
        let sliced = SourceRegistry.allDescriptors.filter { $0.composition == .part }
        #expect(!sliced.isEmpty)
        for group in Set(sliced.map(\.group)) {
            let members = sliced.filter { $0.group == group }
            #expect(members.count >= 2, "\(group) declares one slice and no other")
        }
    }

    @Test("nothing is both a slice and a direction")
    func compositionAndDirectionAreExclusive() {
        // Two directions of a flow are not slices of a whole, and a band drawn
        // below a baseline would be nonsense.
        for descriptor in SourceRegistry.allDescriptors {
            #expect(
                descriptor.direction == nil || descriptor.composition == nil,
                "\(descriptor.id.rawValue) claims to be both"
            )
        }
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
        let bytes = try NetworkSource.readInterfaceTotals(
            matching: NetworkSource.physicalInterfaceNames()
        )
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

    /// Counting the tunnels and Apple's internal interfaces reports more
    /// traffic than crossed the wire — a VPN's bytes appear on both `utun` and
    /// the `en` they leave by. Over-reporting is the worst kind of wrong here,
    /// because the number stays plausible.
    @Test("only Wi-Fi and wired interfaces are counted")
    func networkExcludesVirtualInterfaces() throws {
        let names = try NetworkSource.physicalInterfaceNames()
        #expect(!names.isEmpty, "no physical interface found on a Mac that has one")

        // Loopback, VPN and per-app tunnels, AirDrop, Apple's link-local and
        // internal interfaces, bridges, and the IPv6 transition pseudo-devices.
        let excluded = ["lo", "utun", "awdl", "llw", "anpi", "ap", "bridge", "gif", "stf"]
        for name in names {
            let match = excluded.first { name.hasPrefix($0) }
            #expect(match == nil, "\(name) is not a physical NIC")
        }
    }

    /// Filtering must actually narrow the set. If it silently matched nothing
    /// the gauges would read a flat zero, which looks exactly like an idle
    /// machine.
    @Test("interface filtering narrows the set without emptying it")
    func networkFilterIsSelective() throws {
        let physical = try NetworkSource.physicalInterfaceNames()
        let filtered = try NetworkSource.readInterfaceTotals(matching: physical)
        let everything = try NetworkSource.readInterfaceTotals(
            matching: Set(NetworkSource.allInterfaceNames())
        )
        #expect(everything.bytesIn >= filtered.bytesIn, "filtering added traffic")
        #expect(filtered.bytesIn > 0, "no physical interface reported any traffic since boot")
    }

    /// Latency must never go absent while the operation counts are present.
    ///
    /// It used to be reported only when operations had completed, which made it
    /// the one metric of this source's six that could vanish on an idle tick.
    /// The UI reads an absent metric as "not available on this machine", so the
    /// Disk Latency card flapped between its chart and that notice twice a
    /// second on an idle machine (#5). This test does not need a busy disk or an
    /// idle one — the invariant holds either way, which is the point.
    @Test("disk latency is reported on every tick that has operation counts")
    func diskLatencyNeverGoesAbsent() throws {
        let source = DiskSource()
        _ = try source.read(at: 0)
        Thread.sleep(forTimeInterval: 0.2)
        let present = try Set(source.read(at: 0.2).samples.map(\.metric))

        #expect(present.contains(DiskSource.readsPerSecond), "no read rate to compare against")
        #expect(
            present.contains(DiskSource.writesPerSecond),
            "no write rate to compare against"
        )
        #expect(present.contains(DiskSource.readLatency), "read latency went absent")
        #expect(present.contains(DiskSource.writeLatency), "write latency went absent")
    }

    /// Zero is a legitimate latency, and an idle interval reports it. What it
    /// must never be is negative or absurd.
    @Test("disk latency is a plausible non-negative duration")
    func diskLatencyRange() throws {
        let source = DiskSource()
        _ = try source.read(at: 0)
        Thread.sleep(forTimeInterval: 0.2)
        let latencies = try source.read(at: 0.2).samples.filter {
            $0.metric == DiskSource.readLatency || $0.metric == DiskSource.writeLatency
        }
        #expect(!latencies.isEmpty)
        for sample in latencies {
            #expect(sample.value >= 0, "\(sample.metric) went negative")
            // A mean latency above a second over a 200 ms window would mean the
            // arithmetic is wrong, not that the disk is slow.
            #expect(sample.value < 1, "\(sample.metric) is not a plausible mean latency")
        }
    }

    /// The first tick has no previous counter reading, so there is genuinely no
    /// rate yet — which is not the same thing as an idle interval, and must not
    /// be reported as a latency of zero.
    @Test("the first disk read yields no latency at all")
    func diskLatencyNeedsTwoReadings() throws {
        let source = DiskSource()
        let first = try Set(source.read(at: 0).samples.map(\.metric))
        #expect(!first.contains(DiskSource.readLatency))
        #expect(!first.contains(DiskSource.writeLatency))
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

    /// Sensors are the one source whose metric list differs per machine — a
    /// fanless laptop has no fans, a Mac mini has no battery — so what is
    /// asserted is that whatever it *does* declare, it can read, in range.
    @Test("every sensor a machine declares reads a plausible value")
    func sensors() throws {
        let source = SMCSource()
        guard !source.descriptors.isEmpty else { return } // no SMC on this machine
        #expect(source.descriptors.allSatisfy {
            ["Temperature", "Power", "Fans"].contains($0.group)
        })

        let batch = try source.read(at: 0)
        let declared = Set(source.descriptors.map(\.id))
        #expect(batch.samples.allSatisfy { declared.contains($0.metric) },
                "a sample arrived for a metric that was never declared")

        let units = Dictionary(
            source.descriptors.map { ($0.id, $0.unit) }, uniquingKeysWith: { first, _ in first }
        )
        for sample in batch.samples {
            switch units[sample.metric] {
            // Nothing in a room is at absolute zero, and silicon that reached
            // 150 °C would have shut the machine down.
            case .celsius: #expect(sample.value > 0 && sample.value < 150,
                                   "\(sample.metric) = \(sample.value) °C")
            // Zero watts is real on a laptop running from its battery.
            case .watts: #expect(sample.value >= 0 && sample.value < 1000,
                                 "\(sample.metric) = \(sample.value) W")
            case .rpm: #expect(sample.value >= 0 && sample.value < 20000,
                               "\(sample.metric) = \(sample.value) rpm")
            default: Issue.record("sensor \(sample.metric) has an unexpected unit")
            }
        }
    }

    /// The key name is the whole addressing scheme, so a code that does not
    /// survive the round trip reads a different sensor than the one asked for.
    @Test("SMC keys round-trip through their four-character code")
    func smcKeyCodes() {
        for name in ["Tp00", "TC0P", "F0Ac", "PDTR", "#KEY"] {
            #expect(SMC.name(SMC.code(name)) == name)
        }
        // Type codes are space-padded on the wire and named without it.
        #expect(SMC.name(SMC.code("flt ")) == "flt")
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

    @Test("the machine describes itself for the About panel")
    func machineInfo() {
        let machine = MachineInfo.current
        #expect(!machine.model.isEmpty)
        #expect(!machine.chip.isEmpty)
        #expect(machine.cores > 0)
        #expect(machine.memoryBytes > 0)
        // "Apple M4, 10 cores, 16 GB" — three facts, no empty fields between
        // the commas even when a sysctl key is missing.
        #expect(machine.hardwareSummary.contains(machine.chip))
        #expect(!machine.hardwareSummary.contains(", ,"))
    }
}
