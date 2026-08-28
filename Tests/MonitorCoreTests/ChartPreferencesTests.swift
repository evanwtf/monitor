import Foundation
@testable import MonitorCore
import Testing

private func metric(
    _ id: String, _ name: String, group: String,
    direction: MetricDirection? = nil,
    composition: MetricComposition? = nil
) -> MetricDescriptor {
    MetricDescriptor(
        id: MetricID(id), name: name, group: group, unit: .bitsPerSecond,
        direction: direction, composition: composition
    )
}

private let app = metric("memory.app", "App", group: "Memory", composition: .part)
private let wired = metric("memory.wired", "Wired", group: "Memory", composition: .part)
private let free = metric("memory.free", "Free", group: "Memory", composition: .part)
private let used = metric("memory.used", "Used", group: "Memory", composition: .aggregate)
private let swap = metric("memory.swap.used", "Swap", group: "Memory")

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

@Suite("ChartStack")
struct ChartStackTests {
    @Test("The slices of a whole stack")
    func stacksParts() {
        #expect(ChartStack.parts(of: [app, wired, free]).count == 3)
    }

    @Test("A sum of the slices never stacks")
    func aggregateStaysOut() {
        // Memory Used is app plus wired plus compressed. Stacked, it would
        // count those three a second time and put the top of the card at nearly
        // twice the RAM in the machine.
        let stack = ChartStack.parts(of: [app, wired, free, used])
        #expect(!stack.contains(used.id))
        #expect(stack.count == 3)
    }

    @Test("A metric that is neither never stacks")
    func unrelatedStaysOut() {
        // Swap is on disk. It shares the card, and it is not a slice of the
        // machine's RAM.
        #expect(!ChartStack.parts(of: [app, wired, swap]).contains(swap.id))
    }

    @Test("One slice on its own is not a stack")
    func singlePart() {
        // A single band is an area chart with extra steps.
        #expect(ChartStack.parts(of: [app]).isEmpty)
        #expect(ChartStack.parts(of: [app, used, swap]).isEmpty)
        #expect(ChartStack.parts(of: []).isEmpty)
    }

    @Test("The slices keep the order the card draws them in")
    func keepsOrder() {
        // The stack is drawn bottom-up in this order, and the order is the
        // reader's own layout order.
        #expect(ChartStack.parts(of: [free, app, wired]) == [free.id, app.id, wired.id])
    }

    @Test("A card cannot be both a stack and a pair")
    func stacksAndPairsAreExclusive() {
        // Two directions of a flow are not slices of a whole. Nothing declares
        // both, and a band drawn below a baseline would be nonsense.
        #expect(ChartStack.parts(of: [netIn, netOut]).isEmpty)
        #expect(ChartMirror.pair(for: [app, wired]) == nil)
    }
}

@Suite("ChartPreferences")
struct ChartPreferencesTests {
    @Test("The two that change the picture are off; the one that adds a number is on")
    func defaults() {
        #expect(ChartPreferences.default.mirrorsPairs == false)
        #expect(ChartPreferences.default.stacksParts == false)
        // Shipped off, the reaction to the finished feature was "I don't see
        // it". A total adds a number beside one already there rather than
        // changing what the chart means, so it does not need switching on.
        #expect(ChartPreferences.default.showsTotals)
        // Horizontal is easier to read wherever there is room for it, and on
        // every card but the narrowest there is.
        #expect(ChartPreferences.default.rotatesTimeLabels == false)
        #expect(ChartPreferences.default.mirror(for: [netIn, netOut]) == nil)
        #expect(ChartPreferences.default.stack(for: [app, wired, free]).isEmpty)
    }

    @Test("Switched on, a card of slices stacks and everything else does not")
    func onlyPartsStack() {
        let preferences = ChartPreferences(stacksParts: true)
        #expect(preferences.stack(for: [app, wired, free]).count == 3)
        #expect(preferences.stack(for: [netIn, netOut]).isEmpty)
    }

    @Test("The settings are independent")
    func settingsAreIndependent() {
        let stacking = ChartPreferences(mirrorsPairs: false, stacksParts: true)
        #expect(stacking.mirror(for: [netIn, netOut]) == nil)
        #expect(!stacking.stack(for: [app, wired]).isEmpty)
        // Totals are a number in the legend, not a change to the picture, so
        // they must not turn either of the other two on by arriving.
        let totals = ChartPreferences(showsTotals: true)
        #expect(totals.mirror(for: [netIn, netOut]) == nil)
        #expect(totals.stack(for: [app, wired]).isEmpty)
    }

    @Test("Switched on, a pair mirrors and everything else does not")
    func onlyPairsMirror() {
        let preferences = ChartPreferences(mirrorsPairs: true)
        #expect(preferences.mirror(for: [netIn, netOut]) != nil)
        #expect(preferences.mirror(for: [netIn]) == nil)
    }

    @Test("Round-trips through Codable")
    func codable() throws {
        let preferences = ChartPreferences(
            mirrorsPairs: true, stacksParts: true,
            showsTotals: true, rotatesTimeLabels: true
        )
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(ChartPreferences.self, from: data) == preferences)
    }

    @Test("A stored value written before a setting existed still decodes")
    func decodesMissingKeys() throws {
        let data = Data("{}".utf8)
        #expect(try JSONDecoder().decode(ChartPreferences.self, from: data) == .default)
        // The shape a 1.4 install actually has on disk: the two keys that
        // existed then, and nothing about totals. It must keep its answers to
        // the questions it was asked rather than reset all three.
        let stored = Data(#"{"mirrorsPairs":true,"stacksParts":true}"#.utf8)
        let decoded = try JSONDecoder().decode(ChartPreferences.self, from: stored)
        #expect(decoded.mirrorsPairs)
        #expect(decoded.stacksParts)
        // An upgrade from a version without the key gets the new default, not
        // false: a missing key means "never asked", not "switched off".
        #expect(decoded.showsTotals)
        #expect(decoded.rotatesTimeLabels == false)
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
