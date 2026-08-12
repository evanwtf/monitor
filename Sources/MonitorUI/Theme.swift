import SwiftUI

/// The instrument-panel palette.
///
/// Dark on purpose, and not merely as a style choice: this is a window that
/// sits open on a second display for hours. A bright panel in the corner of
/// your eye all day is tiring, and a light needle on a dark dial is the higher
/// contrast pairing for a thin moving element.
public enum Theme {
    /// Every size that decides how much of the dashboard fits on screen.
    ///
    /// Gathered here rather than spread across the views because they are one
    /// decision, not eight: the panel is either dense enough to take in at a
    /// glance without scrolling, or it is legible at arm's length, and moving
    /// between those two means moving all of these together.
    ///
    /// Every size that decides how much of the dashboard fits on screen.
    ///
    /// What made only four cards visible was not card height — it was the
    /// column count. A 380pt minimum in a 1156pt content width fits **two**
    /// columns, so seven cards needed four rows. Halving that minimum gives
    /// four columns and the same seven cards land in two rows, which is why the
    /// charts here are barely shorter than they were: the width came down by
    /// half, the height did not have to.
    ///
    /// That matters because the premise of the app is charts big enough to
    /// read. Activity Monitor's are not, and shrinking far enough lands in the
    /// same place — a literal half-of-both left five cramped columns, wrapped
    /// legends, colliding time labels and a third of the window empty.
    public enum Layout {
        /// Gauge dials are square, so this is their height too.
        ///
        /// The wall is resizable — the rule under it is a drag handle — so these
        /// are the ends of that travel rather than a fixed size. The floor is
        /// where the readout stops being legible; the ceiling is a sanity limit,
        /// and on any window narrower than four ceiling-sized dials the real
        /// limit is the width, computed by `DashboardView`.
        public static let gaugeMinimum = 90.0
        public static let gaugeMaximum = 360.0
        /// Where the wall starts, and what it had been fixed at before it could
        /// be dragged.
        public static let gaugeDefault = 130.0
        /// Height of the drag handle's hit area. The rule it draws is one point;
        /// this is how close the pointer has to get, and 11 is the smallest that
        /// does not feel like a game of darts.
        public static let dividerGrab = 11.0
        /// Minimum chart card width. The grid fits as many columns as it can,
        /// so this is really a column count in disguise: 260 gives four columns
        /// at 1180pt and three at 900.
        public static let chartMinimum = 260.0
        /// The plot area alone, not counting the card's header and padding.
        ///
        /// Sized so that two rows of cards plus the gauge wall fill a 1180×900
        /// window rather than leaving the bottom third empty. It is a *minimum*,
        /// so a shorter window scrolls — which is the right way round: the
        /// charts stay readable and the window decides how many you see at once.
        public static let chartMinHeight = 250.0

        public static let gridSpacing = 12.0
        public static let pagePadding = 14.0
        public static let cardPadding = 10.0
        public static let cardCorner = 9.0

        /// Type inside a card. At four columns a 13pt title and a row of legend
        /// entries no longer share a line.
        public static let cardTitle = 12.0
        public static let cardLegend = 10.0
        public static let axisLabel = 8.0
        /// The dial's label, which sits under the dial rather than on its face:
        /// at 130pt across there is no room on the face for "Network Out"
        /// without it running into the ticks.
        public static let gaugeCaption = 10.0

        /// The caption grows with its dial, but not linearly and not past 18pt.
        ///
        /// Everything inside `GaugeView` is a fraction of the radius, so a dial
        /// dragged to twice the size scales whole. A caption that stayed at 10pt
        /// under a 300pt dial would be the one part that visibly did not, and
        /// one that kept exact proportion would be shouting.
        public static func gaugeCaptionSize(forGauge size: Double) -> Double {
            min(18, max(gaugeCaption, size * 0.077))
        }
    }

    public static let background = Color(red: 0.07, green: 0.07, blue: 0.08)
    public static let panel = Color(red: 0.12, green: 0.12, blue: 0.13)
    public static let panelEdge = Color(red: 0.28, green: 0.28, blue: 0.30)
    public static let dialFace = Color(red: 0.16, green: 0.16, blue: 0.17)

    public static let tick = Color(white: 0.72)
    public static let tickMinor = Color(white: 0.40)
    public static let label = Color(white: 0.62)
    public static let readout = Color(white: 0.93)

    /// The seven-segment readout inset in a dial face.
    ///
    /// Amber rather than the blue of the needle, so that at a glance the two
    /// carry different information instead of reading as one blue smear. It is
    /// also the one warm colour on the panel, which is what makes the readout
    /// findable on a wall of otherwise identical dials.
    public static let lcd = Color(red: 1.00, green: 0.71, blue: 0.24)
    /// Unlit segments. Faint, but not invisible: seeing where the bars *would*
    /// be is what makes the thing read as a display rather than as a stencil,
    /// and it fixes the width of the readout so it cannot shift sideways as
    /// digits come and go.
    public static let lcdGhost = Color(red: 1.00, green: 0.71, blue: 0.24).opacity(0.11)
    /// Behind the segments. Slightly warm and darker than the dial face, the
    /// way a recessed panel actually looks.
    public static let lcdPanel = Color(red: 0.07, green: 0.06, blue: 0.05)

    /// The needle. One colour for every gauge — a needle that changes colour
    /// per metric turns a dashboard into a fruit salad and stops the eye from
    /// reading position, which is the only thing a needle is for.
    public static let needle = Color(red: 0.16, green: 0.68, blue: 0.96)
    public static let redline = Color(red: 0.85, green: 0.20, blue: 0.16)

    /// Series colours for charts, in assignment order. Chosen to stay
    /// distinguishable for the common forms of colour blindness — a red and
    /// green pair on the same chart is the usual failure.
    public static let series: [Color] = [
        Color(red: 0.16, green: 0.68, blue: 0.96),
        Color(red: 0.98, green: 0.68, blue: 0.18),
        Color(red: 0.56, green: 0.78, blue: 0.32),
        Color(red: 0.78, green: 0.46, blue: 0.92),
        Color(red: 0.94, green: 0.42, blue: 0.44),
        Color(red: 0.36, green: 0.84, blue: 0.80),
    ]

    public static func seriesColor(_ index: Int) -> Color {
        series[index % series.count]
    }

    /// The bezel. A soft radial fill reads as a physical ring without the
    /// heavy gloss and drop shadows that dated the skeuomorphic era.
    public static let bezel = LinearGradient(
        colors: [Color(white: 0.42), Color(white: 0.16), Color(white: 0.34)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
