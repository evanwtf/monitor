@testable import MonitorCore
import Testing

@Suite("SevenSegment")
struct SevenSegmentTests {
    /// The whole point of putting the mapping in Core is that it can be checked
    /// exhaustively without a screen. A wrong bar makes a 6 read as an 8, which
    /// is the kind of error a monitoring tool must not have.
    @Test("digits light the traditional segments")
    func digits() {
        #expect(SevenSegment.mask(for: "0") == [.a, .b, .c, .d, .e, .f])
        #expect(SevenSegment.mask(for: "1") == [.b, .c])
        #expect(SevenSegment.mask(for: "2") == [.a, .b, .d, .e, .g])
        #expect(SevenSegment.mask(for: "3") == [.a, .b, .c, .d, .g])
        #expect(SevenSegment.mask(for: "4") == [.b, .c, .f, .g])
        #expect(SevenSegment.mask(for: "5") == [.a, .c, .d, .f, .g])
        #expect(SevenSegment.mask(for: "6") == [.a, .c, .d, .e, .f, .g])
        #expect(SevenSegment.mask(for: "7") == [.a, .b, .c])
        #expect(SevenSegment.mask(for: "8") == .all)
        #expect(SevenSegment.mask(for: "9") == [.a, .b, .c, .d, .f, .g])
    }

    /// Every digit must differ from every other. Two digits sharing a mask
    /// would be indistinguishable on the panel.
    @Test("no two digits share a mask")
    func digitsAreDistinct() {
        let masks = (0...9).compactMap { SevenSegment.mask(for: Character("\($0)")) }
        #expect(masks.count == 10)
        #expect(Set(masks).count == 10)
    }

    @Test("a 6 and a 9 keep the bars that tell them from 8")
    func sixAndNine() {
        let six = SevenSegment.mask(for: "6")
        let nine = SevenSegment.mask(for: "9")
        #expect(six?.contains(.b) == false, "a 6 with its top-right bar lit is an 8")
        #expect(nine?.contains(.e) == false, "a 9 with its bottom-left bar lit is an 8")
    }

    @Test("a minus is the middle bar alone, a space is nothing")
    func punctuation() {
        #expect(SevenSegment.mask(for: "-") == .g)
        #expect(SevenSegment.mask(for: " ") == [])
    }

    @Test("characters the display cannot show are refused rather than faked")
    func unknown() {
        #expect(SevenSegment.mask(for: "%") == nil)
        #expect(SevenSegment.mask(for: "M") == nil)
    }

    /// The property the whole readout rests on: a decimal point rides the cell
    /// before it, so a value keeps the same number of cells whether or not it
    /// has a fractional part. Otherwise the readout jumps sideways every time
    /// the value crosses a decade.
    @Test("a decimal point takes no cell of its own")
    func decimalPoint() {
        let withPoint = SevenSegment.glyphs(for: "2.35")
        let without = SevenSegment.glyphs(for: "235")
        #expect(withPoint.count == 3)
        #expect(withPoint.count == without.count)
        #expect(withPoint[0].point)
        #expect(withPoint[1].point == false)
        #expect(withPoint.map(\.mask) == without.map(\.mask))
    }

    @Test("a leading point gets a blank cell to sit on")
    func leadingPoint() {
        let glyphs = SevenSegment.glyphs(for: ".5")
        #expect(glyphs.count == 2)
        #expect(glyphs[0].mask == [])
        #expect(glyphs[0].point)
        #expect(glyphs[1].mask == SevenSegment.mask(for: "5"))
    }

    /// A blank holds its cell. That is what lets the gauge's `xxxx.yy` field
    /// keep the decimal point in one place: the leading blanks of `   4.23`
    /// occupy the same three cells that `5012` fills.
    @Test("a blank takes a cell so a fixed field stays aligned")
    func blanksHoldTheirCell() {
        let small = SevenSegment.glyphs(for: "   4.23")
        let large = SevenSegment.glyphs(for: "5012.66")
        #expect(small.count == large.count)
        #expect(small.firstIndex(where: \.point) == large.firstIndex(where: \.point))
        // Hoisted out of `#expect`: the macro expansion cannot digest a nested
        // key path, and swiftformat rewrites the equivalent closure into one.
        let leadingCellsAreBlank = small.prefix(3).allSatisfy(\.mask.isEmpty)
        #expect(leadingCellsAreBlank)
    }

    @Test("unshowable characters are dropped from a run")
    func runSkipsUnknown() {
        #expect(SevenSegment.glyphs(for: "12 MB").map(\.mask) == [
            SevenSegment.mask(for: "1"),
            SevenSegment.mask(for: "2"),
            SevenSegment.mask(for: " "),
        ].compactMap(\.self))
    }
}
