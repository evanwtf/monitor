import Foundation
@testable import MonitorCore
import Testing

private let netIn = MetricID("net.bits.in")
private let netOut = MetricID("net.bits.out")
private let diskRead = MetricID("disk.bytes.read")
private let diskWritten = MetricID("disk.bytes.written")

@Suite("ChartMirror")
struct ChartMirrorTests {
    @Test("A card drawing both directions is a pair")
    func recognisesPairs() {
        #expect(ChartMirror.pair(for: [netIn, netOut])?.up == netIn)
        #expect(ChartMirror.pair(for: [diskRead, diskWritten])?.down == diskWritten)
    }

    @Test("Order on the card does not decide which way is up")
    func orderIndependent() {
        // The card lists its series in layout order, which the reader can
        // change. Which one points down is not that list's business.
        #expect(ChartMirror.pair(for: [netOut, netIn])?.up == netIn)
    }

    @Test("One direction on its own is not a pair")
    func halfPair() {
        // Otherwise switching Network Out off leaves a trace hanging below an
        // empty top half, which reads as a bug rather than as a choice.
        #expect(ChartMirror.pair(for: [netIn]) == nil)
        #expect(ChartMirror.pair(for: [netOut]) == nil)
    }

    @Test("A card that is not two opposite directions is not a pair")
    func notAPair() {
        let cpu = MetricID("cpu.total")
        let user = MetricID("cpu.user")
        #expect(ChartMirror.pair(for: [cpu, user]) == nil)
        // Two sensors sharing a card are two readings, not two directions.
        #expect(ChartMirror.pair(for: []) == nil)
    }

    @Test("Halves of different pairs are not a pair")
    func crossedPair() {
        #expect(ChartMirror.pair(for: [netIn, diskWritten]) == nil)
    }

    @Test("A card carrying a pair and something else is not mirrored")
    func pairPlusExtra() {
        // Three traces and only two of them opposite has no honest baseline.
        #expect(ChartMirror.pair(for: [netIn, netOut, diskRead]) == nil)
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
        #expect(preferences.mirror(for: [MetricID("cpu.total")]) == nil)
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
