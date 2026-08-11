import SwiftUI

/// The instrument-panel palette.
///
/// Dark on purpose, and not merely as a style choice: this is a window that
/// sits open on a second display for hours. A bright panel in the corner of
/// your eye all day is tiring, and a light needle on a dark dial is the higher
/// contrast pairing for a thin moving element.
public enum Theme {
    public static let background = Color(red: 0.07, green: 0.07, blue: 0.08)
    public static let panel = Color(red: 0.12, green: 0.12, blue: 0.13)
    public static let panelEdge = Color(red: 0.28, green: 0.28, blue: 0.30)
    public static let dialFace = Color(red: 0.16, green: 0.16, blue: 0.17)

    public static let tick = Color(white: 0.72)
    public static let tickMinor = Color(white: 0.40)
    public static let label = Color(white: 0.62)
    public static let readout = Color(white: 0.93)

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
