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

    public init(
        title: String,
        series: [(descriptor: MetricDescriptor, points: [Sample])],
        window: TimeInterval,
        isUnavailable: Bool = false
    ) {
        self.title = title
        self.series = series
        self.window = window
        self.isUnavailable = isUnavailable
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

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(
                    size: Theme.Layout.cardTitle,
                    weight: .semibold,
                    design: .rounded
                ))
                .foregroundStyle(Theme.readout)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 4)
            // Current values in the header rather than in a legend below the
            // chart: the number and its colour swatch belong together, and it
            // saves a row of chrome per card.
            ForEach(Array(series.enumerated()), id: \.offset) { index, entry in
                if let latest = entry.points.last {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Theme.seriesColor(index))
                            .frame(width: 7, height: 7)
                        Text(entry.descriptor.name)
                            .foregroundStyle(Theme.label)
                            .lineLimit(1)
                        Text(Format.value(latest.value, unit: entry.descriptor.unit))
                            .foregroundStyle(Theme.readout)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .font(.system(size: Theme.Layout.cardLegend, design: .rounded))
                }
            }
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
        .frame(maxWidth: .infinity, minHeight: Theme.Layout.chartMinHeight)
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
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                ForEach(entry.points, id: \.timestamp) { sample in
                    LineMark(
                        x: .value("Time", Date(timeIntervalSince1970: sample.timestamp)),
                        y: .value("Value", sample.value)
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
                        Text(Format.axisLabel(value, unit: unit))
                            .font(.system(size: Theme.Layout.axisLabel, design: .rounded))
                            .foregroundStyle(Theme.label)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Theme.panelEdge.opacity(0.3))
                AxisValueLabel(format: .dateTime.hour().minute(), centered: false)
                    .font(.system(size: Theme.Layout.axisLabel, design: .rounded))
                    .foregroundStyle(Theme.label)
            }
        }
        .frame(minHeight: Theme.Layout.chartMinHeight)
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
    private var yDomain: ClosedRange<Double> {
        if let descriptor = series.first?.descriptor {
            if descriptor.unit == .fraction { return 0...1 }
            if let maximum = descriptor.nominalMaximum { return 0...maximum }
        }
        // Scaled to what is on screen, not to the whole buffer. Otherwise a
        // spike eight minutes off the left of a two-minute window flattens
        // everything you can actually see.
        let peak = visible.flatMap { $0.points.map(\.value) }.max() ?? 1
        return 0...max(peak * 1.15, .leastNonzeroMagnitude)
    }
}
