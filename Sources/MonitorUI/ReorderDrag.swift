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
    /// Carried as text in a private format, and parsed strictly.
    ///
    /// A custom `UTType` would say what this is far better, and it was the
    /// first attempt — but `UTType(exportedAs:)` needs a declaration in an
    /// `Info.plist`, and `swift run monitor` has no bundle. The type went
    /// unregistered, no drop destination ever matched it, and dragging did
    /// nothing at all in exactly the build the development loop uses. A type
    /// that only works when packaged is a type that gets broken between
    /// packages.
    ///
    /// So: text, with a prefix nothing else produces. Foreign text dropped on
    /// the panel fails to parse and the move is refused, which is the property
    /// the custom type was there for.
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.encoded, importing: PanelTile.init(encoded:))
    }

    private static let prefix = "wtf.evan.monitor.tile"

    var encoded: String {
        switch self {
        case let .gauge(id): "\(Self.prefix)/gauge/\(id)"
        case let .chart(group): "\(Self.prefix)/chart/\(group)"
        }
    }

    /// Splits on the first two separators only, so a group name containing one
    /// survives the round trip.
    init(encoded: String) throws {
        let parts = encoded.split(
            separator: "/",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        guard parts.count == 3, parts[0] == Self.prefix, !parts[2].isEmpty else {
            throw MetricSourceError.readFailed("drag payload", code: 0)
        }
        switch parts[1] {
        case "gauge": self = .gauge(String(parts[2]))
        case "chart": self = .chart(String(parts[2]))
        default: throw MetricSourceError.readFailed("drag payload", code: 0)
        }
    }
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

    /// The tile's own width, so a drop can be told which half it landed in.
    /// Measured from the background, which is not hit-testable — see below.
    @State private var width = 0.0

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
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { width = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, new in width = new }
                }
            )
            // One drop destination over the whole tile, with the half worked
            // out from where the pointer is.
            //
            // The two halves were two `Color.clear` overlays with
            // `contentShape(Rectangle())` before, and that is a trap worth
            // remembering: an overlay sits *above* the content, so it swallowed
            // the mouse-down and `.draggable` never saw a press. Nothing could
            // be dragged at all. A drop destination does not need to be a hit
            // target for ordinary clicks — a drag session hit-tests separately
            // — so measuring the width from the background and asking the drop
            // where it is costs nothing and leaves the press alone.
            .onDrop(
                of: [.utf8PlainText],
                delegate: TileDrop(
                    tile: tile, width: { width }, target: $target, onDrop: onDrop
                )
            )
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
}

/// Tracks which half of a tile the pointer is over, and resolves the drop.
private struct TileDrop: DropDelegate {
    let tile: PanelTile
    /// Read at drop time rather than captured, because the delegate is rebuilt
    /// on every body pass and the width is measured after the first one.
    let width: () -> Double
    @Binding var target: DropTarget?
    let onDrop: (PanelTile, PanelTile, DropTarget.Edge) -> Void

    private func edge(_ info: DropInfo) -> DropTarget.Edge {
        let half = width() / 2
        // Before the width is known, treat everything as the leading half:
        // "insert before this tile" is the safe reading, and it is only ever
        // the case for the first frame of the very first drag.
        guard half > 0 else { return .leading }
        return info.location.x < half ? .leading : .trailing
    }

    func dropEntered(info: DropInfo) {
        target = DropTarget(tile: tile, edge: edge(info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        target = DropTarget(tile: tile, edge: edge(info))
        return DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        if target?.tile == tile { target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.utf8PlainText]).first
        else { return false }
        let edge = edge(info)
        target = nil
        // Loading is asynchronous even for a drag that never left this process,
        // so the move happens a beat after the drop rather than inside it.
        _ = provider.loadTransferable(type: PanelTile.self) { result in
            guard case let .success(dragged) = result else { return }
            Task { @MainActor in onDrop(dragged, tile, edge) }
        }
        return true
    }
}
