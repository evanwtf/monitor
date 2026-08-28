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
    /// The series to draw as stacked bands rather than as lines. Empty is the
    /// ordinary card.
    ///
    /// Passed in rather than worked out here, for the same reason `mirror` is:
    /// whether to stack is a preference, and a card does not read preferences.
    public var stacked: [MetricID] = []
    /// The widest interval one sample may be credited with when totalling, or
    /// nil to draw no totals at all.
    ///
    /// One optional rather than a flag and a number, because neither is any use
    /// without the other: a total cannot be taken without knowing the sampling
    /// clock, and the clock belongs to the model. Passed in for the same reason
    /// `mirror` and `stacked` are — whether to show totals is a preference, and
    /// a card does not read preferences.
    public var totalGap: TimeInterval?
    /// Draw the time labels on their side. Passed in for the same reason the
    /// three above are: it is a preference, and a card does not read them.
    public var rotatesTimeLabels: Bool = false

    public init(
        title: String,
        series: [(descriptor: MetricDescriptor, points: [Sample])],
        window: TimeInterval,
        isUnavailable: Bool = false,
        plotHeight: Double = Theme.Layout.chartMinHeight,
        mirror: MetricPair? = nil,
        stacked: [MetricID] = [],
        totalGap: TimeInterval? = nil,
        rotatesTimeLabels: Bool = false
    ) {
        self.title = title
        self.series = series
        self.window = window
        self.isUnavailable = isUnavailable
        self.plotHeight = plotHeight
        self.mirror = mirror
        // A card is one or the other. Two directions of a flow are not slices
        // of a whole, so nothing declares both — but drawing bands below a
        // baseline would be nonsense, so it cannot happen by accident either.
        self.stacked = mirror == nil ? stacked : []
        self.totalGap = totalGap
        self.rotatesTimeLabels = rotatesTimeLabels
    }

    public var body: some View {
        // Bound once and passed down rather than read as a computed property
        // from three places: it walks every series' whole buffer, and the card
        // redraws on every tick.
        let totals = totals
        return VStack(alignment: .leading, spacing: 5) {
            header(totals)
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
    @ViewBuilder
    private func header(_ totals: [MetricID: WindowTotal.Result]) -> some View {
        let span = totalSpan(totals)
        if totals.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    titleText(span: span)
                    Spacer(minLength: 0)
                    legend(totals, span: span)
                }
                VStack(alignment: .leading, spacing: 4) {
                    titleText(span: span)
                    legend(totals, span: span)
                }
            }
        } else {
            // A table always goes under the title, never beside it. `ViewThatFits`
            // is the right question for a wrapping row of entries and the wrong
            // one for a column of figures: pushed to the right of the title on a
            // wide card, the Totals heading floats in the middle of the header
            // with nothing under it that reads as a table.
            VStack(alignment: .leading, spacing: 4) {
                titleText(span: span)
                legend(totals, span: span)
            }
        }
    }

    /// The title, and the span the totals cover when there are any.
    ///
    /// Stated once here rather than after every entry. The History picker is
    /// global, so repeating "/ 2 min" four times down a legend is four copies
    /// of one fact — and the legend is the part of the card with the least room
    /// to spare.
    private func titleText(span: TimeInterval?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.system(
                    size: Theme.Layout.cardTitle,
                    weight: .semibold,
                    design: .rounded
                ))
                .foregroundStyle(Theme.readout)
                .lineLimit(1)
            if let span {
                Text(Format.span(span))
                    .font(.system(size: Theme.Layout.cardLegend, design: .monospaced))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
            }
        }
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
    /// The legend: a wrapping row of entries, or a small table when the card
    /// has totals to line up.
    ///
    /// Two shapes rather than one because the cards differ. A card of levels —
    /// Memory's seven slices, five temperature sensors — has nothing to total
    /// and wants `FlowLayout`, which spends card height only when the entries
    /// genuinely do not fit across. A card of rates has a second number per
    /// series, and numbers in a wrapped row do not line up: the totals ended up
    /// at four different left edges down the same card, which is what a column
    /// is for.
    ///
    /// Only five groups accumulate — Disk, Disk Ops, Network, Network Packets,
    /// Memory Paging — and every one of them has exactly two series, so the
    /// table is three rows at its tallest.
    @ViewBuilder
    private func legend(
        _ totals: [MetricID: WindowTotal.Result], span: TimeInterval?
    ) -> some View {
        if totals.isEmpty {
            flowLegend
        } else {
            tableLegend(totals, span: span)
        }
    }

    /// Entries wrapped across the card, for a legend with no totals column.
    ///
    /// An `HStack` given less width than its children want compresses them, and
    /// compressed entries truncate to nothing readable; `FlowLayout` spends card
    /// height instead, which is the cheaper of the two.
    private var flowLegend: some View {
        FlowLayout(horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(Array(series.enumerated()), id: \.offset) { index, entry in
                if let latest = entry.points.last {
                    HStack(spacing: 4) {
                        swatch(entry.descriptor, index: index)
                        nameText(entry.descriptor)
                        valueText(entry.descriptor, latest: latest)
                    }
                }
            }
        }
        .font(.system(size: Theme.Layout.cardLegend, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Series down the left, rate then total across, with the totals column
    /// headed and right-justified.
    ///
    /// Right-justified because these are magnitudes, and magnitudes are read by
    /// the position of their last digit: `104 MB` over `48 MB` aligned on the
    /// left puts the hundreds above the tens and hides the difference the column
    /// exists to show. Headed because a second bare number beside a rate does
    /// not say what it is — the span beside the card's title says *how long*,
    /// and this says *of what*.
    private func tableLegend(
        _ totals: [MetricID: WindowTotal.Result], span: TimeInterval?
    ) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            GridRow {
                // One merged cell across the swatch, name and rate columns: a
                // merged cell adds nothing to their widths, so the heading
                // cannot widen the table it labels.
                Color.clear.frame(width: 0, height: 0).gridCellColumns(3)
                Text("Totals")
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                    .gridColumnAlignment(.trailing)
            }
            ForEach(Array(series.enumerated()), id: \.offset) { index, entry in
                if let latest = entry.points.last {
                    GridRow {
                        swatch(entry.descriptor, index: index)
                        nameText(entry.descriptor)
                        valueText(entry.descriptor, latest: latest)
                        totalText(
                            entry.descriptor,
                            total: totals[entry.descriptor.id],
                            span: span
                        )
                    }
                }
            }
        }
        .font(.system(size: Theme.Layout.cardLegend, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Filled for a band, hollow for a line — the same distinction the chart
    /// makes, so the key does not have to be guessed at.
    private func swatch(_ descriptor: MetricDescriptor, index: Int) -> some View {
        Group {
            if stacked.isEmpty || isBand(descriptor) {
                Circle().fill(Theme.seriesColor(index))
            } else {
                Circle().strokeBorder(Theme.seriesColor(index), lineWidth: 1.5)
            }
        }
        .frame(width: 7, height: 7)
    }

    private func nameText(_ descriptor: MetricDescriptor) -> some View {
        Text(descriptor.name)
            .foregroundStyle(Theme.label)
            .lineLimit(1)
    }

    /// The current reading, in a slot pre-sized to the widest its unit can
    /// produce.
    ///
    /// Monospaced and reserved for the same reason: a legend whose entries
    /// change width is a legend that shuffles sideways while you are reading it.
    /// A monospaced face stops individual digits from changing width as they
    /// change value; the reserved slot stops the *number of* digits from moving
    /// everything else, which is what made a series climbing from `1%` to `100%`
    /// appear to wiggle the whole card. `.monospacedDigit()` is not enough on
    /// its own — it equalises digit widths but reserves nothing.
    private func valueText(_ descriptor: MetricDescriptor, latest: Sample) -> some View {
        ZStack(alignment: .leading) {
            // A ZStack takes the width of its widest child, so a reading wider
            // than the reservation grows the slot rather than being clipped —
            // the reservation is a floor.
            Text(Format.widestValue(unit: descriptor.unit)).hidden()
            Text(Format.value(latest.value, unit: descriptor.unit))
                .foregroundStyle(Theme.readout)
                .lineLimit(1)
        }
    }

    /// How much moved, right-justified under the Totals heading.
    ///
    /// Dimmed when this series covers materially less of the window than the
    /// span printed beside the title — one source failed for a stretch while
    /// its neighbour on the card kept reading. The ordinary case, where every
    /// series covers the same span, spends no ink saying so.
    ///
    /// The slot is reserved here too, and its contents pushed right, so the
    /// digits stay in one column as their magnitude changes.
    @ViewBuilder
    private func totalText(
        _ descriptor: MetricDescriptor, total: WindowTotal.Result?, span: TimeInterval?
    ) -> some View {
        if let total,
           let text = Format.total(total.value, unit: descriptor.unit),
           let widest = Format.widestTotal(unit: descriptor.unit)
        {
            let isShort = span.map { $0 - total.covered > (totalGap ?? 0) } ?? false
            ZStack(alignment: .trailing) {
                Text(widest).hidden()
                Text(text)
                    .foregroundStyle(isShort ? Theme.label : Theme.readout)
                    .lineLimit(1)
            }
        } else {
            // A series on a card that has totals but cannot produce one of its
            // own still needs its cell, or the row below slides up a column.
            Color.clear.frame(width: 0, height: 0)
        }
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

    // MARK: - Totals

    /// How much moved over the window, per series, in the rate's own base unit.
    ///
    /// Reads `series` rather than `visible`: `WindowTotal` needs the sample just
    /// *before* the window's left edge to measure the partial interval that
    /// straddles it, and `visible` has already thrown that one away.
    private var totals: [MetricID: WindowTotal.Result] {
        guard let totalGap else { return [:] }
        let end = xRange.end
        var results: [MetricID: WindowTotal.Result] = [:]
        for entry in series where entry.descriptor.unit.accumulation != nil {
            results[entry.descriptor.id] = WindowTotal.total(
                of: entry.points, window: window, now: end, maximumGap: totalGap
            )
        }
        return results
    }

    /// The span printed beside the title: the window when the card really has
    /// it, and what the card actually has when it does not.
    ///
    /// Ten seconds after launch the buffer holds ten seconds, and "2 min" over
    /// a number covering a twelfth of that is the quiet kind of wrong. The
    /// tolerance is one `totalGap`, because a card is never going to cover its
    /// window to the microsecond and "119 s" beside a picker reading "2 min"
    /// reads as a fault rather than as precision.
    private func totalSpan(_ totals: [MetricID: WindowTotal.Result]) -> TimeInterval? {
        guard let totalGap, let longest = totals.values.map(\.covered).max() else {
            return nil
        }
        return window - longest > totalGap ? longest : window
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
                    let x = PlottableValue.value(
                        "Time", Date(timeIntervalSince1970: sample.timestamp)
                    )
                    let y = PlottableValue.value(
                        "Value", plotted(sample.value, of: entry.descriptor)
                    )
                    // Bands for the slices, lines for everything else on the
                    // card. Swift Charts stacks area marks that share an x and
                    // differ by series, and leaves the line marks alone, so the
                    // two kinds sit on one chart without arguing.
                    if stacked.contains(entry.descriptor.id) {
                        AreaMark(x: x, y: y)
                            .foregroundStyle(Theme.seriesColor(index).opacity(0.85))
                            .interpolationMethod(.monotone)
                    } else {
                        LineMark(x: x, y: y)
                            .foregroundStyle(Theme.seriesColor(index))
                            .interpolationMethod(.monotone)
                            .lineStyle(lineStyle)
                    }
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
            AxisMarks(values: xTicks) { value in
                AxisGridLine().foregroundStyle(Theme.panelEdge.opacity(0.3))
                AxisValueLabel(centered: true) {
                    if let date = value.as(Date.self) { timeLabel(date) }
                }
            }
        }
        // `chartBackground` rather than an overlay: it hands over the same
        // proxy and sits *under* the chart, where it cannot swallow the
        // mouse-down that a tile's drag gesture needs. An overlay here is the
        // trap `ReorderDrag` documents.
        .chartBackground { proxy in
            GeometryReader { geometry in
                // The plot rect, not the chart's own width. The y-axis and its
                // labels are outside it, and they are much wider on "20 MB/s"
                // than on "0%" — which is exactly when the room runs out.
                let width = proxy.plotFrame.map { geometry[$0].width } ?? geometry.size.width
                Color.clear.preference(key: PlotWidthKey.self, value: width)
            }
        }
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

    /// One time label, upright or on its side.
    ///
    /// `rotationEffect` turns the glyphs and not the layout, so the rotated
    /// case needs `fixedSize` to stop the frame squeezing the text first, and
    /// then a frame of its own — otherwise the axis reserves the label's width
    /// and none of its height, and the turned text draws over the chart.
    @ViewBuilder
    private func timeLabel(_ date: Date) -> some View {
        let text = Text(date, format: timeFormat)
            .font(.system(size: Theme.Layout.timeLabel, design: .rounded))
            .foregroundStyle(Theme.label)
            .lineLimit(1)
        if rotatesTimeLabels {
            text
                .fixedSize()
                .rotationEffect(.degrees(-90))
                .frame(
                    width: Theme.Layout.timeLabelRotated.width,
                    height: Theme.Layout.timeLabelRotated.height
                )
        } else {
            text
        }
    }

    /// The labelled instants and their spacing — see `ChartAxis`, which is
    /// where the arithmetic lives and where it is tested.
    private var marks: ChartAxis.Marks {
        let range = xRange
        return ChartAxis.marks(
            from: range.start, to: range.end,
            plotWidth: plotWidth, rotated: rotatesTimeLabels
        )
    }

    private var xTicks: [Date] {
        marks.times.map { Date(timeIntervalSince1970: $0) }
    }

    /// No AM/PM, and no leading zero on the hour. A card shows at most ten
    /// minutes of history, so which half of the day it is was never in
    /// question, and "0" in "08:52:30" is a character that carries nothing
    /// across eight labels that have no room for it. The minutes and seconds
    /// keep both digits: those are positional, and "8:5:3" is not a time.
    private var timeFormat: Date.FormatStyle {
        let base = Date.FormatStyle.dateTime
            .hour(.defaultDigits(amPM: .omitted))
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
        //
        // A stack is measured by its total height, not by its tallest band. Its
        // top is what the eye reads, and scaling to one band would push the
        // stack out through the top of the card.
        let peak = max(
            visible.flatMap { $0.points.map(\.value) }.max() ?? 1, stackedPeak ?? 0
        )
        return max(peak * 1.15, .leastNonzeroMagnitude)
    }

    /// Solid on an ordinary card, dashed on a stacked one.
    ///
    /// A line among bands is a different kind of statement and has to look like
    /// one. Memory Used is a *sum* of three of the bands under it and Swap is
    /// not in the machine's RAM at all, so drawing them in the same solid
    /// stroke the card uses elsewhere invites reading them as one more slice.
    private var lineStyle: StrokeStyle {
        stacked.isEmpty
            ? StrokeStyle(lineWidth: 2)
            : StrokeStyle(lineWidth: 2, dash: [4, 3])
    }

    /// Whether this series is drawn as a band. The legend asks so its swatch
    /// can say the same thing the chart does.
    private func isBand(_ descriptor: MetricDescriptor) -> Bool {
        stacked.contains(descriptor.id)
    }

    /// The tallest the stack gets inside the window: the parts summed per
    /// timestamp, then the largest of those sums.
    private var stackedPeak: Double? {
        guard !stacked.isEmpty else { return nil }
        var totals: [TimeInterval: Double] = [:]
        for entry in visible where stacked.contains(entry.descriptor.id) {
            for sample in entry.points {
                totals[sample.timestamp, default: 0] += sample.value
            }
        }
        return totals.values.max()
    }
}
