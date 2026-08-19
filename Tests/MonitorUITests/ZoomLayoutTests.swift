import CoreGraphics
import MonitorCore
@testable import MonitorUI
import Testing

@Suite("Zoom layout")
struct ZoomLayoutTests {
    @Test("The zoom leaves a margin of panel showing")
    func leavesAMargin() {
        let panel = CGSize(width: 1200, height: 800)
        let zoom = ZoomLayout.size(panel: panel)
        #expect(zoom.width < panel.width)
        #expect(zoom.height < panel.height)
    }

    @Test("A panel that has not been measured still gets a readable zoom")
    func unmeasuredPanel() {
        let zoom = ZoomLayout.size(panel: .zero)
        #expect(zoom == ZoomLayout.smallest)
    }

    @Test("A tiny window does not produce a tiny zoom")
    func tinyWindow() {
        let zoom = ZoomLayout.size(panel: CGSize(width: 300, height: 200))
        #expect(zoom.width == ZoomLayout.smallest.width)
        #expect(zoom.height == ZoomLayout.smallest.height)
    }

    @Test("A very large display does not stretch the zoom without limit")
    func hugeDisplay() {
        let zoom = ZoomLayout.size(panel: CGSize(width: 6000, height: 4000))
        #expect(zoom.width == ZoomLayout.largest.width)
        #expect(zoom.height == ZoomLayout.largest.height)
    }

    @Test("The zoom grows with the panel between its two ends")
    func growsWithThePanel() {
        let small = ZoomLayout.size(panel: CGSize(width: 900, height: 600))
        let large = ZoomLayout.size(panel: CGSize(width: 1400, height: 900))
        #expect(large.width > small.width)
        #expect(large.height > small.height)
    }

    @Test("A zoomed chart is taller than one on the panel")
    func plotIsTaller() {
        let zoom = ZoomLayout.size(panel: CGSize(width: 1200, height: 800))
        #expect(ZoomLayout.plotHeight(in: zoom) > PanelSize.chartHeight.initial)
    }

    @Test("The plot never goes below the smallest chart the panel allows")
    func plotHasAFloor() {
        let plot = ZoomLayout.plotHeight(in: CGSize(width: 520, height: 120))
        #expect(plot == PanelSize.chartHeight.minimum)
    }

    @Test("A zoomed dial is bigger than the largest one on the wall")
    func dialIsBigger() {
        let zoom = ZoomLayout.size(panel: CGSize(width: 1200, height: 800))
        #expect(ZoomLayout.dialEdge(in: zoom) > PanelSize.gauge.maximum)
    }

    @Test("A zoomed dial fits inside the zoom")
    func dialFits() {
        for panel in [
            CGSize(width: 700, height: 500),
            CGSize(width: 1200, height: 800),
            CGSize(width: 6000, height: 4000),
        ] {
            let zoom = ZoomLayout.size(panel: panel)
            let edge = ZoomLayout.dialEdge(in: zoom)
            #expect(edge <= zoom.width)
            #expect(edge <= zoom.height)
        }
    }

    @Test("A tile identifies itself, and two tiles do not collide")
    func tileIdentity() {
        #expect(PanelTile.chart("Memory").id == PanelTile.chart("Memory").id)
        #expect(PanelTile.chart("Memory").id != PanelTile.gauge("Memory").id)
        #expect(PanelTile.gauge("cpu.total").id != PanelTile.gauge("cpu.user").id)
    }
}
