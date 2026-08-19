import Foundation
@testable import MonitorCore
import Testing

@Suite("ChartAxis")
struct ChartAxisTests {
    /// The four windows the toolbar offers.
    static let windows: [TimeInterval] = [60, 120, 300, 600]

    @Test("A narrow card gets fewer labels than a wide one")
    func countFollowsWidth() {
        #expect(ChartAxis.maximumTicks(width: 260) < ChartAxis.maximumTicks(width: 600))
    }

    @Test("Never fewer than two labels, never more than five")
    func countIsBounded() {
        #expect(ChartAxis.maximumTicks(width: 0) == ChartAxis.fewest)
        #expect(ChartAxis.maximumTicks(width: 10000) == ChartAxis.most)
        #expect(ChartAxis.maximumTicks(width: .nan) == ChartAxis.fewest)
    }

    @Test("Every window on every card width gets at least two labels")
    func neverFewerThanTwo() {
        // The bug this pins: at five minutes on a narrow card the interval
        // chosen was 300 s for a 300 s window, and a 300 s window inset at both
        // ends contains a multiple of 300 only sometimes. The axis emptied
        // itself. Swept across a whole window's worth of start offsets, because
        // whether an absolute boundary falls inside depends on where the window
        // happens to sit.
        for span in Self.windows {
            for width in [200.0, 260, 400, 600, 900] {
                let maximum = ChartAxis.maximumTicks(width: width)
                for offset in stride(from: 0.0, to: span, by: span / 20) {
                    let marks = ChartAxis.marks(
                        from: 1_700_000_000 + offset,
                        to: 1_700_000_000 + offset + span,
                        maximumTicks: maximum
                    )
                    #expect(marks.times.count >= ChartAxis.fewest)
                }
            }
        }
    }

    @Test("The card's room is respected wherever two labels fit inside it")
    func staysWithinTheRoom() {
        // Not an absolute cap: two labels beat a tidy count, so a window that
        // cannot show two within the room is allowed to go over. It must not go
        // far over.
        for span in Self.windows {
            for width in [200.0, 260, 400, 600, 900] {
                let maximum = ChartAxis.maximumTicks(width: width)
                for offset in stride(from: 0.0, to: span, by: span / 20) {
                    let marks = ChartAxis.marks(
                        from: 1_700_000_000 + offset,
                        to: 1_700_000_000 + offset + span,
                        maximumTicks: maximum
                    )
                    #expect(marks.times.count <= max(maximum, ChartAxis.fewest) + 3)
                }
            }
        }
    }

    @Test("The interval does not change as the window slides")
    func strideIsStable() {
        // The flicker this replaces: choosing the interval by counting the
        // ticks it produced made a narrow ten-minute card flip between 300 s
        // and 120 s as the window moved, so the labels jumped between two and
        // five every few seconds.
        for span in Self.windows {
            for width in [200.0, 260, 400, 600, 900] {
                let maximum = ChartAxis.maximumTicks(width: width)
                let strides = Set(
                    stride(from: 0.0, to: span, by: 1).map { offset in
                        ChartAxis.marks(
                            from: 1_700_000_000 + offset,
                            to: 1_700_000_000 + offset + span,
                            maximumTicks: maximum
                        ).stride
                    }
                )
                #expect(strides.count == 1)
            }
        }
    }

    @Test("Ticks land on round clock boundaries")
    func onBoundaries() {
        let marks = ChartAxis.marks(from: 1_000_007, to: 1_000_127, maximumTicks: 3)
        #expect(!marks.times.isEmpty)
        #expect(marks.times.allSatisfy {
            $0.truncatingRemainder(dividingBy: marks.stride) == 0
        })
        #expect(ChartAxis.strides.contains(marks.stride))
    }

    @Test("A tick is an instant: the window slides, the tick does not")
    func ticksAreInstants() {
        // Ticks placed at fractions of the window keep still while their labels
        // count up in real time. A gridline has to travel left with the data it
        // marks and keep the time it names.
        let early = ChartAxis.times(from: 0, to: 120, stride: 30)
        let later = ChartAxis.times(from: 10, to: 130, stride: 30)
        let shared = Set(early).intersection(later)
        #expect(!shared.isEmpty)
        #expect(shared.allSatisfy { $0.truncatingRemainder(dividingBy: 30) == 0 })
        // And the window having moved on drops the tick that scrolled off.
        #expect(!later.contains(where: { $0 < 10 }))
    }

    @Test("No tick sits against either edge of the window")
    func insetFromTheEdges() {
        // A label is centred on its tick, so one on the edge is half cut off.
        let times = ChartAxis.times(from: 0, to: 600, stride: 60)
        #expect(times.allSatisfy { $0 > 0 && $0 < 600 })
    }

    @Test("An empty or backwards window has no ticks")
    func degenerateWindow() {
        #expect(ChartAxis.times(from: 100, to: 100, stride: 30).isEmpty)
        #expect(ChartAxis.times(from: 200, to: 100, stride: 30).isEmpty)
        #expect(ChartAxis.times(from: 0, to: 120, stride: 0).isEmpty)
        #expect(ChartAxis.marks(from: 100, to: 100, maximumTicks: 3).times.isEmpty)
    }

    @Test("The roundest interval that fits is the one chosen")
    func prefersCoarse() {
        // Ten minutes across five labels could be 15 s; it should be 120 s.
        let marks = ChartAxis.marks(
            from: 1_700_000_000, to: 1_700_000_600, maximumTicks: 5
        )
        #expect(marks.stride >= 120)
    }

    @Test("Seconds appear only when a stride lands twice inside one minute")
    func secondsWhenNeeded() {
        #expect(ChartAxis.showsSeconds(stride: 30))
        #expect(!ChartAxis.showsSeconds(stride: 60))
        #expect(!ChartAxis.showsSeconds(stride: 300))
    }
}
