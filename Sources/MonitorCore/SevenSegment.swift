import Foundation

/// Which of a seven-segment cell's bars a character lights.
///
/// This lives in MonitorCore rather than beside the view because "a 4 lights
/// b, c, f and g" is a fact about the display, not about drawing: it can be
/// stated and tested without a screen, and it is the half of the readout most
/// likely to be quietly wrong. Segment geometry — where the bars sit, how they
/// taper — belongs to the view.
///
/// Segments carry their traditional names, going clockwise from the top bar
/// with the middle bar last:
///
///     ┌── a ──┐
///     f       b
///     ├── g ──┤
///     e       c
///     └── d ──┘
public enum SevenSegment {
    public struct Mask: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let a = Mask(rawValue: 1 << 0)
        public static let b = Mask(rawValue: 1 << 1)
        public static let c = Mask(rawValue: 1 << 2)
        public static let d = Mask(rawValue: 1 << 3)
        public static let e = Mask(rawValue: 1 << 4)
        public static let f = Mask(rawValue: 1 << 5)
        public static let g = Mask(rawValue: 1 << 6)

        /// Every bar lit: an `8`, and the shape the unlit ghosts trace.
        public static let all: Mask = [.a, .b, .c, .d, .e, .f, .g]
    }

    /// One cell of the display: the bars it lights, and whether the dot to its
    /// right is on.
    public struct Glyph: Hashable, Sendable {
        public let mask: Mask
        public let point: Bool

        public init(mask: Mask, point: Bool = false) {
            self.mask = mask
            self.point = point
        }
    }

    /// The bars a character lights, or nil for anything this display cannot
    /// show. A `.` is not a character here — it belongs to the cell before it,
    /// which is what `glyphs(for:)` handles.
    public static func mask(for character: Character) -> Mask? {
        switch character {
        case "0": [.a, .b, .c, .d, .e, .f]
        case "1": [.b, .c]
        case "2": [.a, .b, .d, .e, .g]
        case "3": [.a, .b, .c, .d, .g]
        case "4": [.b, .c, .f, .g]
        case "5": [.a, .c, .d, .f, .g]
        case "6": [.a, .c, .d, .e, .f, .g]
        case "7": [.a, .b, .c]
        case "8": .all
        case "9": [.a, .b, .c, .d, .f, .g]
        case "-": .g
        case " ": []
        default: nil
        }
    }

    /// Lay a string out as cells.
    ///
    /// A decimal point takes no cell of its own — it lights the dot belonging
    /// to the digit it follows, exactly as hardware does. That is what keeps
    /// "2.35" and "235" the same width, so the readout does not shift sideways
    /// as a value crosses a decade. A leading point, having no digit to attach
    /// to, gets a blank cell to sit on.
    ///
    /// Characters the display cannot show are dropped rather than substituted:
    /// a wrong glyph in a readout is worse than a missing one.
    public static func glyphs(for text: String) -> [Glyph] {
        var result: [Glyph] = []
        for character in text {
            if character == "." || character == "," {
                if result.isEmpty {
                    result.append(Glyph(mask: [], point: true))
                } else if result[result.count - 1].point {
                    // Two points in a row cannot share a cell.
                    result.append(Glyph(mask: [], point: true))
                } else {
                    result[result.count - 1] = Glyph(
                        mask: result[result.count - 1].mask, point: true
                    )
                }
                continue
            }
            if let mask = mask(for: character) {
                result.append(Glyph(mask: mask))
            }
        }
        return result
    }
}
