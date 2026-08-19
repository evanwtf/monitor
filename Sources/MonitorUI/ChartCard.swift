import Charts
import MonitorCore
import SwiftUI

/// A history chart for one group of metrics.
///
/// Deliberately large. Activity Monitor's charts are a couple of centimetres
/// tall, which is enough to see that something happened and never enough to see
/// what. A chart here gets real vertical space and a y-axis that is labelled.
public struct ChartCard: View {
    public let title: String
    public let series: [(descriptor: MetricDescriptor, points: [Sample])]
    /// Seconds of history to show.
    public let window: TimeInterval
    public var isUnavailable: Bool = false
    /// Height of the plot area, from the size popover. Still a *minimum*: a
    /// card whose legend wraps to three lines grows rather than squeezing the
    /// chart out of it.
    public var plotHeight: Double = Theme.Layout.chartMinHeight
    /// The two opposite directions this card draws, when it is drawing them
    /// mirrored. Nil is the ordinary card: every series upward from zero.
    ///
    /// Passed in rather than worked out here, because whether to mirror is a
    /// preference and a card does not read preferences.
    public var mirror: MetricPair?

    public init(
        title: String,
        series: [(descriptor: MetricDescriptor, points: [Sample])],
        window: TimeInterval,
        isUnavailable: Bool = false,
        plotHeight: Double = Theme.Layout.chartMinHeight,
        mirror: MetricPair? = nil
    ) {
        self.title = title
        self.series = series
        self.window = window
        self.isUnavailable = isUnavailable
        self.plotHeight = plotHeight
        self.mirror = mirror
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            if isUnavailable {
                unavailableNotice
            } else {
                chart
            }
        }
        .padding(Theme.Layout.cardPadding)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Layout.cardCorner))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Layout.cardCorner)
                .strokeBorder(Theme.panelEdge.opacity(0.5), lineWidth: 1)
        )
    }

    /// Title and legend on one line when they fit, and on two when they do not.
    ///
    /// Decided by fit rather than by counting series, which is what it used to
    /// do. A count cannot know how wide the words are: "Memory Paging" beside
    /// "Page in 19/s  Page out 4.0/s" is two series and does not fit, while
    /// "GPU" beside "GPU 0%  VRAM 1.9 GB" is two series and does. With the
    /// title `fixedSize` — it must not truncate — a header that did not fit
    /// pushed the whole card wider than its grid column, which stretched the
    /// row and left the legend running out through the card's edge.
    ///
    /// `ViewThatFits` proposes the column's width to the first arrangement and
    /// falls back to the second, so the compact line survives wherever there is
    /// room for it.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                titleText
                Spacer(minLength: 0)
                legend
            }
            VStack(alignment: .leading, spacing: 4) {
                titleText
                legend
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.system(
                size: Theme.Layout.cardTitle,
                weight: .semibold,
                design: .rounded
            ))
            .foregroundStyle(Theme.readout)
            .lineLimit(1)
            .fixedSize()
    }

    /// Current values in the header rather than in a legend below the chart:
    /// the number and its colour swatch belong together, and it saves a row of
    /// chrome per card.
    ///
    /// Wrapped rather than laid out in one line. An `HStack` given less width
    /// than its children want compresses them, and compressed legend entries
    /// truncate to nothing readable; `FlowLayout` spends card height instead,
    /// which is the cheaper of the two.
    private var legend: some View {
        FlowLayout(horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(Array(series.enumerated()), id: \.offset) { index, entry in
                if let latest = entry.points.last {
                    legendEntry(entry.descriptor, index: index, latest: latest)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// One legend entry: colour swatch, series name, current value.
    ///
    /// Monospaced, and the value sits in a slot pre-sized to the widest reading
    /// its unit can produce. Both matter for the same reason: a legend whose
    /// entries change width is a legend that shuffles sideways while you are
    /// reading it. A monospaced face stops individual digits from changing width
    /// as they change value; the reserved slot stops the *number of* digits from
    /// moving everything else, which is what made a series climbing from `1%` to
    /// `100%` appear to wiggle the whole card.
    ///
    /// `.monospacedDigit()` is not enough on its own — it equalises digit widths
    /// but reserves nothing, so `1%` and `100%` still occupy different space.
    private func legendEntry(
        _ descriptor: MetricDescriptor, index: Int, latest: Sample
    ) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Theme.seriesColor(index))
                .frame(width: 7, height: 7)
            Text(descriptor.name)
                .foregroundStyle(Theme.label)
                .lineLimit(1)
            ZStack(alignment: .leading) {
                // Reserves the slot. A ZStack takes the width of its widest
                // child, so a reading wider than the reservation grows the slot
                // rather than being clipped — the reservation is a floor.
                Text(Format.widestValue(unit: descriptor.unit))
                    .hidden()
                Text(Format.value(latest.value, unit: descriptor.unit))
                    .foregroundStyle(Theme.readout)
                    .lineLimit(1)
            }
        }
        .font(.system(size: Theme.Layout.cardLegend, design: .monospaced))
    }

    private var unavailableNotice: some View {
        // Say the metric cannot be read. Drawing zero would be a lie that looks
        // exactly like a healthy idle machine.
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text("Not available on this machine")
        }
        .font(.system(size: Theme.Layout.cardLegend))
        .foregroundStyle(Theme.label)
        .frame(maxWidth: .infinity, minHeight: plotHeight)
    }

    /// Points inside the visible window, per series.
    ///
    /// The buffer holds ten minutes and the window is usually one or two, so
    /// most of what it holds is off the left of the chart. Swift Charts does not
    /// drop marks outside the x domain — it draws them anyway, outside the plot
    /// area and straight through the axis labels and the card's own edge — so
    /// they have to be filtered out here rather than left to the scale.
    /// `chartPlotStyle` clips what remains; this keeps the mark count honest as
    /// well, since drawing 1200 points to show 240 is nine-tenths wasted.
    private var visible: [(descriptor: MetricDescriptor, points: [Sample])] {
        let range = xRange
        return series.map { entry in
            (entry.descriptor, entry.points.filter { $0.timestamp >= range.start })
        }
    }

    private var chart: some View {
        // Bound once rather than referenced inside the result builder: the
        // tuple-typed series makes the builder expensive enough to type-check
        // that the compiler warns about it.
        let entries = visible
        return Chart {
            // The baseline, drawn only when there is one to draw. On an
            // ordinary card zero is the bottom of the plot and the axis already
            // marks it; on a mirrored card it is the line the two directions
            // are read against, and it has to be visible as more than one grid
            // line among several.
            if mirror != nil {
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(Theme.panelEdge)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                ForEach(entry.points, id: \.timestamp) { sample in
                    LineMark(
                        x: .value("Time", Date(timeIntervalSince1970: sample.timestamp)),
                        y: .value("Value", plotted(sample.value, of: entry.descriptor))
                    )
                    .foregroundStyle(Theme.seriesColor(index))
                    .interpolationMethod(.monotone)
                }
                .foregroundStyle(by: .value("Series", entry.descriptor.name))
            }
        }
        .chartForegroundStyleScale(range: Theme.series)
        .chartLegend(.hidden)
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        // Belt and braces with the filtering in `visible`: a sample can still
        // sit fractionally outside the domain at either edge, and an
        // unclipped line drawn past the plot rect runs over the axis labels
        // and out through the side of the card.
        .chartPlotStyle { $0.clipped() }
        .chartYAxis {
            AxisMarks(position: .leading) { mark in
                AxisGridLine().foregroundStyle(Theme.panelEdge.opacity(0.4))
                AxisValueLabel {
                    if let value = mark.as(Double.self),
                       let unit = series.first?.descriptor.unit
                    {
                        // The magnitude, on both sides of the baseline. Below
                        // the line is a direction, not a negative quantity, and
                        // "-50 MB/s" is not a rate anything can achieve.
                        Text(Format.axisLabel(abs(value), unit: unit))
                            .font(.system(size: Theme.Layout.axisLabel, design: .rounded))
                            .foregroundStyle(Theme.label)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: xTicks) { _ in
                AxisGridLine().foregroundStyle(Theme.panelEdge.opacity(0.3))
                AxisValueLabel(format: timeFormat, centered: true)
                    .font(.system(size: Theme.Layout.axisLabel, design: .rounded))
                    .foregroundStyle(Theme.label)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PlotWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(PlotWidthKey.self) { plotWidth = $0 }
        .frame(minHeight: plotHeight)
    }

    /// How wide the card is, which decides how many time labels fit.
    ///
    /// Measured rather than assumed: the width comes from the grid, and the
    /// grid's column width is a slider in the toolbar. A count fixed in the
    /// source is right at exactly one card size.
    @State private var plotWidth = 0.0

    private struct PlotWidthKey: PreferenceKey {
        static let defaultValue = 0.0
        static func reduce(value: inout Double, nextValue: () -> Double) {
            value = max(value, nextValue())
        }
    }

    /// The labelled instants and their spacing — see `ChartAxis`, which is
    /// where the arithmetic lives and where it is tested.
    private var marks: ChartAxis.Marks {
        let range = xRange
        return ChartAxis.marks(
            from: range.start, to: range.end,
            maximumTicks: ChartAxis.maximumTicks(width: plotWidth)
        )
    }

    private var xTicks: [Date] {
        marks.times.map { Date(timeIntervalSince1970: $0) }
    }

    /// No AM/PM. A card shows at most ten minutes of history, so which half of
    /// the day it is was never in question, and those two characters were most
    /// of what made the labels collide.
    private var timeFormat: Date.FormatStyle {
        let base = Date.FormatStyle.dateTime
            .hour(.twoDigits(amPM: .omitted))
            .minute(.twoDigits)
        return ChartAxis.showsSeconds(stride: marks.stride) ? base.second(.twoDigits) : base
    }

    /// The visible time span, as raw timestamps.
    private var xRange: (start: TimeInterval, end: TimeInterval) {
        let end = series.compactMap { $0.points.last?.timestamp }.max()
            ?? Date().timeIntervalSince1970
        return (end - window, end)
    }

    private var xDomain: ClosedRange<Date> {
        let range = xRange
        return Date(timeIntervalSince1970: range.start)...Date(timeIntervalSince1970: range.end)
    }

    /// A fraction metric is pinned to 0...1 so a quiet CPU draws a flat line at
    /// the bottom. Auto-scaling it would magnify 2% noise into a dramatic chart
    /// — the single most common way a system monitor misleads.
    /// Where a sample is drawn, which is not what it is worth.
    ///
    /// Only the picture flips. The sample in the buffer stays positive — a rate
    /// is never negative — so the legend, the formatter, the gauges and the CSV
    /// export all keep reading the number the source produced.
    private func plotted(_ value: Double, of descriptor: MetricDescriptor) -> Double {
        descriptor.id == mirror?.down ? -value : value
    }

    private var yDomain: ClosedRange<Double> {
        let top = upperBound
        // Symmetric about zero, so a rate reads the same distance from the
        // baseline whichever way it points. One shared scale, not one per
        // direction: the whole reason the two share a card is to be read
        // against each other, and a card where download dwarfs upload will look
        // nearly flat on the quiet side. That is the honest picture.
        return mirror == nil ? 0...top : -top...top
    }

    private var upperBound: Double {
        if let descriptor = series.first?.descriptor {
            if descriptor.unit == .fraction { return 1 }
            if let maximum = descriptor.nominalMaximum { return maximum }
        }
        // Scaled to what is on screen, not to the whole buffer. Otherwise a
        // spike eight minutes off the left of a two-minute window flattens
        // everything you can actually see.
        let peak = visible.flatMap { $0.points.map(\.value) }.max() ?? 1
        return max(peak * 1.15, .leastNonzeroMagnitude)
    }
}
