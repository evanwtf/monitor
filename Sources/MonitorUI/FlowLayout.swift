import SwiftUI

/// Lays subviews out left to right, wrapping to a new row when the next one
/// would not fit.
///
/// Exists for the legend in a `ChartCard` header. An `HStack` cannot wrap: given
/// less width than its children want it compresses them instead, and a row of
/// legend entries under compression turns into a row of ellipses — which is
/// exactly what the Memory card became, with seven series in a four-column
/// grid. Wrapping trades a few points of card height for entries that are
/// either legible or not drawn at all, and height is the cheaper of the two.
///
/// Rows are packed greedily and the last row is not stretched: the entries are
/// read left to right, so ragged right is correct and justification would put
/// arbitrary gaps between a swatch and the series it belongs to.
struct FlowLayout: Layout {
    /// Horizontal gap between entries in a row.
    var horizontalSpacing: CGFloat = 10
    /// Vertical gap between rows.
    var verticalSpacing: CGFloat = 3

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()
    ) -> CGSize {
        let packed = rows(within: proposal.width ?? .infinity, subviews: subviews)
        let width = packed.map(\.width).max() ?? 0
        let height = packed.map(\.height).reduce(0, +)
            + verticalSpacing * CGFloat(max(0, packed.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()
    ) {
        var y = bounds.minY
        for row in rows(within: proposal.width ?? bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    // Baselines within a row line up when the entries are all
                    // the same type size, which they are; centring keeps a
                    // taller entry from dragging the row's text off the line.
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Greedy packing. An entry wider than the whole line still gets a row of
    /// its own rather than being dropped — overflowing is more useful than
    /// vanishing.
    private func rows(within width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let advance = row.indices.isEmpty ? size.width : size.width + horizontalSpacing
            if !row.indices.isEmpty, row.width + advance > width {
                rows.append(row)
                row = Row()
                row.indices = [index]
                row.width = size.width
                row.height = size.height
            } else {
                row.indices.append(index)
                row.width += advance
                row.height = max(row.height, size.height)
            }
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
