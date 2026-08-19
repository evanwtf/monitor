import Foundation
@testable import MonitorCore
import Testing

private func metric(
    _ id: String, _ name: String, group: String, direction: MetricDirection? = nil
) -> MetricDescriptor {
    MetricDescriptor(
        id: MetricID(id), name: name, group: group, unit: .bitsPerSecond,
        direction: direction
    )
}

private let netIn = metric("net.bits.in", "In", group: "Network", direction: .inbound)
private let netOut = metric("net.bits.out", "Out", group: "Network", direction: .outbound)
private let diskRead = metric("disk.bytes.read", "Read", group: "Disk", direction: .inbound)
private let diskWritten = metric(
    "disk.bytes.written", "Write", group: "Disk", direction: .outbound
)

@Suite("ChartMirror")
struct ChartMirrorTests {
    @Test("A card drawing both directions is a pair")
    func recognisesPairs() {
        #expect(ChartMirror.pair(for: [netIn, netOut])?.up == netIn.id)
        #expect(ChartMirror.pair(for: [diskRead, diskWritten])?.down == diskWritten.id)
    }

    @Test("Inbound is up whichever order the card lists them in")
    func orderIndependent() {
        // The card lists its series in layout order, which the reader can
        // change. Which one points down is not that list's business.
        #expect(ChartMirror.pair(for: [netOut, netIn])?.up == netIn.id)
    }

    @Test("One direction on its own is not a pair")
    func halfPair() {
        // Otherwise switching Network Out off leaves a trace hanging below an
        // empty top half, which reads as a bug rather than as a choice.
        #expect(ChartMirror.pair(for: [netIn]) == nil)
        #expect(ChartMirror.pair(for: [netOut]) == nil)
        #expect(ChartMirror.pair(for: []) == nil)
    }

    @Test("Metrics without a declared direction never pair")
    func noDirection() {
        // Read and write latency are the case this protects: two measurements
        // of the same kind, not two directions of one flow.
        let readLatency = metric("disk.latency.read", "Read", group: "Disk Latency")
        let writeLatency = metric("disk.latency.write", "Write", group: "Disk Latency")
        #expect(ChartMirror.pair(for: [readLatency, writeLatency]) == nil)
    }

    @Test("Two of the same direction are not a pair")
    func sameDirectionTwice() {
        #expect(ChartMirror.pair(for: [netIn, diskRead]) == nil)
    }

    @Test("A card carrying a pair and something else is not mirrored")
    func pairPlusExtra() {
        // Three traces and only two of them opposite has no honest baseline.
        #expect(ChartMirror.pair(for: [netIn, netOut, diskRead]) == nil)
    }

    @Test("Every source that declares one direction declares the other")
    func directionsComeInPairs() {
        // A group with an inbound metric and no outbound one can never mirror,
        // which is a declaration somebody half finished rather than a choice.
        let all = SourceRegistryFixture.descriptors
        let directed = all.filter { $0.direction != nil }
        #expect(!directed.isEmpty)
        for group in Set(directed.map(\.group)) {
            let members = directed.filter { $0.group == group }
            #expect(members.count(where: { $0.direction == .inbound }) == 1)
            #expect(members.count(where: { $0.direction == .outbound }) == 1)
        }
    }
}

@Suite("ChartPreferences")
struct ChartPreferencesTests {
    @Test("Mirroring is off until it is switched on")
    func offByDefault() {
        #expect(ChartPreferences.default.mirrorsPairs == false)
        #expect(ChartPreferences.default.mirror(for: [netIn, netOut]) == nil)
    }

    @Test("Switched on, a pair mirrors and everything else does not")
    func onlyPairsMirror() {
        let preferences = ChartPreferences(mirrorsPairs: true)
        #expect(preferences.mirror(for: [netIn, netOut]) != nil)
        #expect(preferences.mirror(for: [netIn]) == nil)
    }

    @Test("Round-trips through Codable")
    func codable() throws {
        let preferences = ChartPreferences(mirrorsPairs: true)
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(ChartPreferences.self, from: data) == preferences)
    }

    @Test("A stored value written before a setting existed still decodes")
    func decodesMissingKeys() throws {
        let data = Data("{}".utf8)
        #expect(try JSONDecoder().decode(ChartPreferences.self, from: data) == .default)
    }
}

/// The directions the real sources declare, written out here because
/// `MonitorCore` cannot see `MonitorSources` — it is the layer below it.
///
/// A copy, so it can go stale. `MonitorSourcesTests` checks the real registry
/// against the same rule, which is the test that cannot.
enum SourceRegistryFixture {
    static let descriptors = [
        netIn, netOut, diskRead, diskWritten,
        metric("disk.ops.read", "Reads", group: "Disk Ops", direction: .inbound),
        metric("disk.ops.write", "Writes", group: "Disk Ops", direction: .outbound),
        metric("net.packets.in", "Packets in", group: "Network Packets", direction: .inbound),
        metric(
            "net.packets.out", "Packets out", group: "Network Packets", direction: .outbound
        ),
        metric("memory.pagein.rate", "Page in", group: "Memory Paging", direction: .inbound),
        metric(
            "memory.pageout.rate", "Page out", group: "Memory Paging", direction: .outbound
        ),
        metric("cpu.total", "Total", group: "CPU"),
    ]
}
