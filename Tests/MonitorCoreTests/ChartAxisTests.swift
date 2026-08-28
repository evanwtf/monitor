import Foundation
@testable import MonitorCore
import Testing

@Suite("ChartAxis")
struct ChartAxisTests {
    /// The four windows the toolbar offers.
    static let windows: [TimeInterval] = [60, 120, 300, 600]

    /// Plot widths the panel can really produce: the card slider runs 200 to
    /// 600 points, and the y-axis and its labels come off that before the time
    /// labels see any of it.
    static let plots: [Double] = [130, 160, 200, 260, 380, 560]

    @Test("A narrow plot gets fewer labels than a wide one")
    func countFollowsWidth() {
        #expect(ChartAxis.maximumTicks(width: 120) < ChartAxis.maximumTicks(width: 400))
    }

    @Test("Never fewer than one label, never more than five")
    func countIsBounded() {
        // One, not two. Two is what the axis reaches for, not what it can
        // promise — see `marks`, where fitting wins over the floor.
        #expect(ChartAxis.maximumTicks(width: 0) == 1)
        #expect(ChartAxis.maximumTicks(width: 10000) == ChartAxis.most)
        #expect(ChartAxis.maximumTicks(width: .nan) == 1)
    }

    @Test("A label without seconds needs less room than one with them")
    func coarseStridesAreCheaper() {
        // The fact the arithmetic used to miss. "8:52" is a third narrower than
        // "8:52:30", so budgeting every stride at the wider figure made the
        // coarse strides look as expensive as the fine ones — and the axis
        // never reached for the one a cramped card wanted.
        let withSeconds = ChartAxis.spacing(showsSeconds: true, rotated: false)
        let without = ChartAxis.spacing(showsSeconds: false, rotated: false)
        #expect(without < withSeconds)
        #expect(ChartAxis.spacing(showsSeconds: true, rotated: true) < without)
    }

    @Test("Labels never overlap, at any window, plot or phase")
    func labelsNeverCollide() {
        // The bug that prompted all of this: on a 160-point plot the axis drew
        // four labels 32 points wide with their centres 40 apart, and at the
        // narrowest card they ran into each other. This is that failure stated
        // as arithmetic — the ink two neighbouring labels need against the
        // distance between them.
        for span in Self.windows {
            for width in Self.plots {
                for rotated in [false, true] {
                    for offset in stride(from: 0.0, to: span, by: span / 40) {
                        let start = 1_700_000_000 + offset
                        let marks = ChartAxis.marks(
                            from: start, to: start + span,
                            plotWidth: width, rotated: rotated
                        )
                        guard marks.times.count >= 2 else { continue }
                        let pointsPerSecond = width / span
                        let apart = marks.stride * pointsPerSecond
                        let needed = ChartAxis.spacing(
                            showsSeconds: ChartAxis.showsSeconds(stride: marks.stride),
                            rotated: rotated
                        )
                        #expect(apart >= needed)
                    }
                }
            }
        }
    }

    @Test("Two labels wherever two fit, and never a bare axis")
    func reachesForTwo() {
        // The floor the old rule protected, kept everywhere it can be had. A
        // narrow card showing two minutes is the case that cannot: no stride is
        // both coarse enough to fit and fine enough to guarantee two, and one
        // readable label beats two on top of each other. Sideways labels are
        // how to have both, so the rotated pass demands two outright.
        for span in Self.windows {
            for width in Self.plots {
                for offset in stride(from: 0.0, to: span, by: span / 20) {
                    let start = 1_700_000_000 + offset
                    let upright = ChartAxis.marks(
                        from: start, to: start + span, plotWidth: width
                    )
                    #expect(!upright.times.isEmpty)
                    let turned = ChartAxis.marks(
                        from: start, to: start + span, plotWidth: width, rotated: true
                    )
                    #expect(turned.times.count >= ChartAxis.fewest)
                }
            }
        }
    }

    @Test("Turning the labels never costs a label")
    func rotatingOnlyEverHelps() {
        // The whole promise of the setting: a rotated label is cheaper, so it
        // can only buy a finer stride, never a coarser one.
        for span in Self.windows {
            for width in Self.plots {
                let upright = ChartAxis.marks(
                    from: 1_700_000_000, to: 1_700_000_000 + span, plotWidth: width
                )
                let turned = ChartAxis.marks(
                    from: 1_700_000_000, to: 1_700_000_000 + span,
                    plotWidth: width, rotated: true
                )
                #expect(turned.stride <= upright.stride)
            }
        }
    }

    @Test("Never denser than five labels")
    func neverTooDense() {
        for span in Self.windows {
            for width in Self.plots + [2000] {
                for rotated in [false, true] {
                    let marks = ChartAxis.marks(
                        from: 1_700_000_000, to: 1_700_000_000 + span,
                        plotWidth: width, rotated: rotated
                    )
                    #expect(marks.times.count <= ChartAxis.most)
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
            for width in Self.plots {
                let strides = Set(
                    stride(from: 0.0, to: span, by: 1).map { offset in
                        ChartAxis.marks(
                            from: 1_700_000_000 + offset,
                            to: 1_700_000_000 + offset + span,
                            plotWidth: width
                        ).stride
                    }
                )
                #expect(strides.count == 1)
            }
        }
    }

    @Test("Ticks land on round clock boundaries")
    func onBoundaries() {
        let marks = ChartAxis.marks(from: 1_000_007, to: 1_000_127, plotWidth: 200)
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
        #expect(ChartAxis.marks(from: 100, to: 100, plotWidth: 200).times.isEmpty)
    }

    @Test("A plot with no width still names an interval rather than crashing")
    func noWidthYet() {
        // The first frame, before the geometry reader has reported anything.
        let marks = ChartAxis.marks(from: 0, to: 600, plotWidth: 0)
        #expect(ChartAxis.strides.contains(marks.stride))
        #expect(ChartAxis.marks(from: 0, to: 600, plotWidth: .nan).stride > 0)
    }

    @Test("The roundest interval that fits is the one chosen")
    func prefersCoarse() {
        // Ten minutes on a wide plot could be labelled every 15 s; it should be
        // 120 s. Five labels is as dense as this ever gets.
        let marks = ChartAxis.marks(from: 1_700_000_000, to: 1_700_000_600, plotWidth: 560)
        #expect(marks.stride >= 120)
    }

    @Test("Seconds appear only when a stride lands twice inside one minute")
    func secondsWhenNeeded() {
        #expect(ChartAxis.showsSeconds(stride: 30))
        #expect(!ChartAxis.showsSeconds(stride: 60))
        #expect(!ChartAxis.showsSeconds(stride: 300))
    }

    @Test("The screenshot that started this now fits its plot")
    func theBugThatStartedThis() {
        // Two minutes on the Disk card: about 160 points of plot once "20 MB/s"
        // has taken its side. Four labels went in, 32 points wide, centres 40
        // apart — touching, and overlapping outright on a narrower card.
        let marks = ChartAxis.marks(from: 1_700_000_000, to: 1_700_000_120, plotWidth: 160)
        let apart = marks.stride * (160.0 / 120)
        let needed = ChartAxis.spacing(
            showsSeconds: ChartAxis.showsSeconds(stride: marks.stride), rotated: false
        )
        #expect(apart >= needed)
        #expect(marks.times.count >= ChartAxis.fewest)
    }
}
