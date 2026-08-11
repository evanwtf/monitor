import MonitorCore
import SwiftUI

/// A run of seven-segment digits, drawn rather than typeset.
///
/// macOS ships no seven-segment face and this project takes no third-party
/// dependencies, but a font would be the wrong tool anyway. A font cannot draw
/// the *unlit* segments, and those are what make a readout look like a panel
/// with a display in it rather than a stencil typeface — they also fix the
/// width of every cell, so the number stops shifting sideways as it changes.
///
/// The view fills whatever frame it is given, preserving aspect. A gauge
/// readout has a fixed inset to live in and the string in it varies from `0.02`
/// to `5000`, so scaling to fit is what keeps the widest reading inside the
/// box without shrinking the common ones to nothing.
public struct SevenSegmentText: View {
    public let text: String
    public var color: Color
    /// Unlit segments. Nil draws none.
    public var ghost: Color?

    public init(_ text: String, color: Color = Theme.lcd, ghost: Color? = Theme.lcdGhost) {
        self.text = text
        self.color = color
        self.ghost = ghost
    }

    public var body: some View {
        Canvas { context, size in
            let glyphs = SevenSegment.glyphs(for: text)
            let natural = Geometry.naturalWidth(of: glyphs)
            guard natural > 0, size.width > 0, size.height > 0 else { return }

            // Unit space is one cell high, so the scale factor is also the
            // rendered cell height.
            let scale = min(size.width / natural, size.height)
            let origin = CGPoint(
                x: (size.width - natural * scale) / 2,
                y: (size.height - scale) / 2
            )

            var lit = Path()
            var unlit = Path()
            for (index, glyph) in glyphs.enumerated() {
                Geometry.append(
                    glyph: glyph, at: Double(index) * Geometry.advance,
                    origin: origin, scale: scale,
                    lit: &lit, unlit: &unlit,
                    // A blank cell is a *position*, not a digit, so it gets no
                    // ghosts. Ghosting it draws a faint 8 where no digit is,
                    // and in a fixed field like `   4.23` the three leading
                    // blanks then read as digits at a glance. The cell still
                    // takes its width, so the field stays fixed either way.
                    includeUnlit: ghost != nil && !glyph.mask.isEmpty,
                    // A ghost dot after the final digit reads as a lit decimal
                    // point at a glance, turning `245` into `245.`. Nothing can
                    // follow it, so nothing needs to hold its place.
                    includeUnlitPoint: ghost != nil && index < glyphs.count - 1
                )
            }

            if let ghost {
                context.fill(unlit, with: .color(ghost))
            }
            // A soft bloom under the crisp segments. Lit LCD and VFD segments
            // do bleed a little into the panel around them, and without it the
            // readout reads as flat vector art.
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: scale * 0.06))
                layer.fill(lit, with: .color(color.opacity(0.55)))
            }
            context.fill(lit, with: .color(color))
        }
    }

    /// Where the bars sit inside a cell.
    ///
    /// Every dimension is a fraction of the cell height, so the whole display
    /// scales from one number. The proportions are those of a physical
    /// seven-segment part: cells taller than they are wide, bars about a
    /// seventh of the height, mitred ends meeting at a visible gap.
    enum Geometry {
        static let cellWidth = 0.60
        static let thickness = 0.145
        /// Gap between the mitred ends of adjacent bars.
        static let gap = 0.022
        /// Room to the right of every cell for its decimal point.
        ///
        /// Reserved on every cell, lit or not, exactly as a physical part
        /// does: each digit owns a point position whether or not it uses it.
        /// Claiming the space only when the point is lit would make `2.35`
        /// wider than `235` — and a readout that changes width as its value
        /// crosses a decade is the thing this display exists to stop.
        static let pointAdvance = 0.26
        /// How far right of its own cell the decimal point sits.
        ///
        /// Small on purpose. A point sitting midway between two digits belongs
        /// to neither, and `2.35` becomes a number you have to look at twice;
        /// tucked against the digit it follows, it is unambiguous.
        static let pointInset = 0.012
        /// Diameter of the decimal point, a little fatter than a bar. On a
        /// small dial the readout renders at about 12pt and a point the width
        /// of a segment disappears — which turns `5012.66` into `501266`.
        static let pointSize = 0.19
        /// Horizontal shift at the top of a cell: the lean of an LCD digit.
        static let slant = 0.07

        static let advance = cellWidth + pointAdvance

        static func naturalWidth(of glyphs: [SevenSegment.Glyph]) -> Double {
            guard let last = glyphs.last else { return 0 }
            // The last cell claims its point's width only if the point is lit.
            // Nothing follows it, so the reserved space would just be a margin
            // that pushes the run off centre. Numbers never end in a point, so
            // this does not reintroduce the width variance the reservation
            // exists to prevent.
            let trailing = last.point ? 0 : pointAdvance
            // The slant pushes the top of every cell right of its own box.
            return Double(glyphs.count) * advance - trailing + slant
        }

        /// Adds one cell's bars to the lit and unlit paths.
        ///
        /// `x` is the cell's left edge in unit space; `origin` and `scale` map
        /// unit space to points. The mapping is applied here, point by point,
        /// rather than through the context's transform, so that blur radii and
        /// any other pixel-space effects stay predictable.
        static func append(
            glyph: SevenSegment.Glyph,
            at x: Double,
            origin: CGPoint,
            scale: Double,
            lit: inout Path,
            unlit: inout Path,
            includeUnlit: Bool,
            includeUnlitPoint: Bool
        ) {
            func map(_ px: Double, _ py: Double) -> CGPoint {
                // Lean the digit: full shift at the top of the cell, none at
                // the bottom, so the baseline stays put.
                CGPoint(
                    x: origin.x + (x + px + slant * (1 - py)) * scale,
                    y: origin.y + py * scale
                )
            }

            let half = thickness / 2
            let width = cellWidth

            /// A bar as a mitred hexagon, from one end to the other.
            func bar(
                from start: (Double, Double), to end: (Double, Double), horizontal: Bool
            ) -> Path {
                var path = Path()
                let points: [(Double, Double)] =
                    horizontal
                        ? [
                            (start.0, start.1),
                            (start.0 + half, start.1 - half),
                            (end.0 - half, end.1 - half),
                            (end.0, end.1),
                            (end.0 - half, end.1 + half),
                            (start.0 + half, start.1 + half),
                        ]
                        : [
                            (start.0, start.1),
                            (start.0 + half, start.1 + half),
                            (end.0 + half, end.1 - half),
                            (end.0, end.1),
                            (end.0 - half, end.1 - half),
                            (start.0 - half, start.1 + half),
                        ]
                path.move(to: map(points[0].0, points[0].1))
                for point in points.dropFirst() { path.addLine(to: map(point.0, point.1)) }
                path.closeSubpath()
                return path
            }

            let bars: [(SevenSegment.Mask, Path)] = [
                (.a, bar(from: (gap, half), to: (width - gap, half), horizontal: true)),
                (.g, bar(from: (gap, 0.5), to: (width - gap, 0.5), horizontal: true)),
                (.d, bar(from: (gap, 1 - half), to: (width - gap, 1 - half), horizontal: true)),
                (.f, bar(from: (half, gap), to: (half, 0.5 - gap), horizontal: false)),
                (.b, bar(
                    from: (width - half, gap), to: (width - half, 0.5 - gap), horizontal: false
                )),
                (.e, bar(from: (half, 0.5 + gap), to: (half, 1 - gap), horizontal: false)),
                (.c, bar(
                    from: (width - half, 0.5 + gap), to: (width - half, 1 - gap),
                    horizontal: false
                )),
            ]

            for (segment, path) in bars {
                if glyph.mask.contains(segment) {
                    lit.addPath(path)
                } else if includeUnlit {
                    unlit.addPath(path)
                }
            }

            // The decimal point sits on the baseline, tucked against the digit
            // it belongs to.
            let dot = CGRect(
                origin: map(width + pointInset, 1 - pointSize),
                size: CGSize(width: pointSize * scale, height: pointSize * scale)
            )
            let dotPath = Path(ellipseIn: dot)
            if glyph.point {
                lit.addPath(dotPath)
            } else if includeUnlitPoint {
                unlit.addPath(dotPath)
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        SevenSegmentText("0.02")
        SevenSegmentText("12.4")
        SevenSegmentText("5000")
        SevenSegmentText("1234567890")
    }
    .frame(width: 260, height: 220)
    .padding(24)
    .background(Theme.lcdPanel)
}
