import MonitorCore
import SwiftUI

/// Double-click a tile to read it properly.
///
/// The panel is a wall of tiles sized to be glanced at. When one of them is the
/// reason you opened the app you want it big, and the size sliders are the
/// wrong tool: they resize *every* card and have to be put back afterwards.
///
/// The zoom is a temporary window over the panel — a sheet — and Escape closes
/// it. That leaves the toolbar's history picker and the sampling rate behind
/// it, which is the one thing the sheet costs; what it buys is that the zoom
/// cannot be forgotten about. Nothing stops sampling while it is open: the
/// buffer is shared, so the panel underneath keeps filling and comes back
/// without a gap.
///
/// It is a mode the panel is in, not a property a tile carries. One `@State`
/// value on the dashboard holds it, so opening a second tile closes the first
/// by construction, and it is `@State` rather than `PanelArrangement` because a
/// zoom must not outlive the session or resize anything stored.
enum ZoomLayout {
    /// How much of the panel the zoom covers.
    ///
    /// Not the whole window. A margin of panel showing around the edge is what
    /// says this is a temporary thing over the dashboard rather than a new
    /// screen you have navigated to.
    static let widthFraction = 0.86
    static let heightFraction = 0.82

    /// Used until the panel has been measured, and for a window so small that a
    /// fraction of it is unreadable.
    static let smallest = CGSize(width: 520, height: 360)
    /// A zoom past this is no longer reading a chart, it is stretching one.
    static let largest = CGSize(width: 1400, height: 900)

    /// The sheet's size, from the panel behind it.
    static func size(panel: CGSize) -> CGSize {
        CGSize(
            width: bounded(
                panel.width * widthFraction, smallest.width, largest.width
            ),
            height: bounded(
                panel.height * heightFraction, smallest.height, largest.height
            )
        )
    }

    /// Height for the plot area inside a zoomed chart.
    ///
    /// The card's own header, padding and the sheet's title bar come off the
    /// top; what is left is the picture. A minimum, like everywhere else the
    /// plot height is set, so a short window scrolls rather than squeezing the
    /// chart out of the card.
    static func plotHeight(in size: CGSize) -> Double {
        max(PanelSize.chartHeight.minimum, size.height - chrome)
    }

    /// Edge length for a zoomed dial. Square, so the smaller side decides, and
    /// the caption under it needs a little more room than the chrome.
    static func dialEdge(in size: CGSize) -> Double {
        max(PanelSize.gauge.minimum, min(size.width, size.height) - chrome)
    }

    /// The title bar, the card's header and legend, and the padding around
    /// both. Measured rather than derived: the legend wraps, so this is the
    /// height at which a two-line legend still leaves a chart worth looking at.
    private static let chrome = 140.0

    private static func bounded(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}

/// A tile is its own identity, so `sheet(item:)` can hold one.
extension PanelTile: Identifiable {
    var id: String { encoded }
}

extension View {
    /// Makes a tile open the zoom when it is double-clicked.
    ///
    /// A tile already carries a left-drag to reorder and a right-click to copy.
    /// A count-2 tap gesture is the one that does not fight them: `.draggable`
    /// claims the press only once the pointer moves, and the context menu is a
    /// separate button.
    func zoomable(_ tile: PanelTile, zoomed: Binding<PanelTile?>) -> some View {
        onTapGesture(count: 2) { zoomed.wrappedValue = tile }
    }
}

/// The frame the zoomed tile sits in: a title, a way out, and the tile.
///
/// The Done button carries `cancelAction`, which is what makes Escape close the
/// sheet. A sheet with no cancel action swallows Escape, and a zoom you cannot
/// dismiss with the key everyone reaches for is worse than no zoom.
struct ZoomFrame<Content: View>: View {
    let title: String
    let size: CGSize
    let close: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.gridSpacing) {
            HStack {
                Text(title)
                    .font(.system(
                        size: Theme.Layout.cardTitle + 3,
                        weight: .semibold,
                        design: .rounded
                    ))
                    .foregroundStyle(Theme.readout)
                Spacer(minLength: 12)
                Button("Done", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(Theme.Layout.pagePadding)
        .frame(width: size.width, height: size.height)
        .background(Theme.background)
        // Double-click again to go back, which is the gesture that opened it.
        .onTapGesture(count: 2, perform: close)
        // Escape, for the case where the button has not taken focus.
        .onExitCommand(perform: close)
    }
}
