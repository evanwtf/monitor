import MonitorCore
import SwiftUI
import UniformTypeIdentifiers

/// What is being dragged around the panel.
///
/// One type for both grids, because the two carry different things — a dial is
/// one metric, a card is a whole group — and a drop target must be able to
/// refuse the wrong one. Without the distinction, dragging a dial onto a chart
/// would be a move nobody can make sense of.
enum PanelTile: Codable, Equatable, Hashable, Sendable {
    case gauge(String)
    case chart(String)

    var gauge: MetricID? {
        if case let .gauge(id) = self {
            MetricID(id)
        } else { nil }
    }

    var chart: String? {
        if case let .chart(group) = self {
            group
        } else { nil }
    }
}

extension PanelTile: Transferable {
    /// Carried as JSON on a private type rather than as plain text, so the
    /// panel neither accepts a string dragged in from another app nor offers
    /// its internals to one.
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .monitorPanelTile)
    }
}

extension UTType {
    static let monitorPanelTile = UTType(exportedAs: "wtf.evan.monitor.panel-tile")
}

/// Where an insertion indicator is showing, and for which tile.
///
/// One value for the whole panel rather than a flag per tile: exactly one gap
/// can be the drop target at a time, and separate flags drift apart when a drag
/// leaves one target and enters another in the same frame.
struct DropTarget: Equatable {
    var tile: PanelTile
    /// Which side of `tile` the dragged thing would land on. The gap is always
    /// *before* something in the model, so trailing means "before whatever
    /// comes next", and at the end of a list it means the end.
    var edge: Edge

    enum Edge { case leading, trailing }
}

/// The line drawn in the gap a tile would drop into.
///
/// Drawn as an overlay on the neighbouring tile rather than as a real item in
/// the grid: inserting a placeholder would reflow everything after it on every
/// frame of the drag, which is the panel visibly rearranging itself under the
/// pointer before anything has been dropped.
struct InsertionIndicator: View {
    var isShowing: Bool
    var edge: HorizontalEdge

    var body: some View {
        HStack(spacing: 0) {
            if edge == .trailing { Spacer(minLength: 0) }
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.needle)
                .frame(width: 3)
                .opacity(isShowing ? 1 : 0)
            if edge == .leading { Spacer(minLength: 0) }
        }
        // The gap between tiles is `gridSpacing` wide, so the line sits in it
        // rather than on top of the tile it belongs to.
        .padding(.horizontal, -Theme.Layout.gridSpacing / 2)
        .animation(.easeOut(duration: 0.12), value: isShowing)
        .allowsHitTesting(false)
    }
}

extension View {
    /// Makes a tile draggable, and its two halves drop targets.
    ///
    /// Insert-before rather than swap. For two adjacent tiles the two are the
    /// same gesture; for anything further apart swap flings an unrelated tile
    /// across the panel into the space you just left, which is not what
    /// dragging something looks like anywhere else.
    ///
    /// The drop target is *half* a tile, not a whole one, so the gap you are
    /// aiming at is the nearer one. Whole-tile targets make the last position in
    /// a row unreachable, because there is nothing after it to drop before.
    /// The callback is handed the tile that was dropped on and which half of it
    /// was hit, rather than a resolved neighbour. Only the view has the ordered
    /// list, so only the view can turn "after this one" into "before the next
    /// one" — and the model's move takes a neighbour precisely so nobody has to
    /// compute an index that shifts when the dragged tile is removed.
    func reorderable(
        _ tile: PanelTile,
        target: Binding<DropTarget?>,
        onDrop: @escaping (_ dragged: PanelTile, _ droppedOn: PanelTile,
                           _ edge: DropTarget.Edge) -> Void
    ) -> some View {
        modifier(ReorderableTile(tile: tile, target: target, onDrop: onDrop))
    }
}

private struct ReorderableTile: ViewModifier {
    let tile: PanelTile
    @Binding var target: DropTarget?
    let onDrop: (PanelTile, PanelTile, DropTarget.Edge) -> Void

    func body(content: Content) -> some View {
        content
            .draggable(tile) {
                // The drag preview. A shrunken, dimmed copy reads as "this is
                // the thing you are holding" without repainting a live chart
                // under the pointer at the sampling rate.
                RoundedRectangle(cornerRadius: Theme.Layout.cardCorner)
                    .fill(Theme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Layout.cardCorner)
                            .stroke(Theme.needle, lineWidth: 1)
                    )
                    .frame(width: 120, height: 60)
            }
            .overlay {
                HStack(spacing: 0) {
                    dropHalf(.leading)
                    dropHalf(.trailing)
                }
            }
            .overlay {
                InsertionIndicator(
                    isShowing: target?.tile == tile && target?.edge == .leading,
                    edge: .leading
                )
                InsertionIndicator(
                    isShowing: target?.tile == tile && target?.edge == .trailing,
                    edge: .trailing
                )
            }
    }

    private func dropHalf(_ edge: DropTarget.Edge) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .dropDestination(for: PanelTile.self) { items, _ in
                guard let dragged = items.first else { return false }
                target = nil
                onDrop(dragged, tile, edge)
                return true
            } isTargeted: { isTargeted in
                if isTargeted {
                    target = DropTarget(tile: tile, edge: edge)
                } else if target?.tile == tile, target?.edge == edge {
                    target = nil
                }
            }
    }
}
