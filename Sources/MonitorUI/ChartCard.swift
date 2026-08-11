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
        VStack(alignment: .leading, spacing: 8) {
            header
            if isUnavailable {
                unavailableNotice
            } else {
                chart
            }
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.panelEdge.opacity(0.5), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.readout)
            Spacer()
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
                        Text(Format.value(latest.value, unit: entry.descriptor.unit))
                            .foregroundStyle(Theme.readout)
                            .monospacedDigit()
                    }
                    .font(.system(size: 11, design: .rounded))
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
        .font(.system(size: 11))
        .foregroundStyle(Theme.label)
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private var chart: some View {
        Chart {
            ForEach(Array(series.enumerated()), id: \.offset) { index, entry in
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
        .chartYAxis {
            AxisMarks(position: .leading) { mark in
                AxisGridLine().foregroundStyle(Theme.panelEdge.opacity(0.4))
                AxisValueLabel {
                    if let value = mark.as(Double.self),
                       let unit = series.first?.descriptor.unit
                    {
                        Text(Format.value(value, unit: unit))
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(Theme.label)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.panelEdge.opacity(0.3))
                AxisValueLabel()
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(Theme.label)
            }
        }
        .frame(minHeight: 140)
    }

    private var xDomain: ClosedRange<Date> {
        let end = series.compactMap { $0.points.last?.timestamp }.max() ?? Date()
            .timeIntervalSince1970
        return Date(timeIntervalSince1970: end - window)...Date(timeIntervalSince1970: end)
    }

    /// A fraction metric is pinned to 0...1 so a quiet CPU draws a flat line at
    /// the bottom. Auto-scaling it would magnify 2% noise into a dramatic chart
    /// — the single most common way a system monitor misleads.
    private var yDomain: ClosedRange<Double> {
        if let descriptor = series.first?.descriptor {
            if descriptor.unit == .fraction { return 0...1 }
            if let maximum = descriptor.nominalMaximum { return 0...maximum }
        }
        let peak = series.flatMap { $0.points.map(\.value) }.max() ?? 1
        return 0...max(peak * 1.15, .leastNonzeroMagnitude)
    }
}
