import MonitorCore
import SwiftUI

/// The window.
///
/// Rates on top as gauges, levels below as charts. The split is not decorative:
/// a gauge answers "how hard is this working right now, against what it can
/// do", and a chart answers "what has been happening". Disk and network
/// throughput are the first question; CPU and memory are the second.
public struct DashboardView: View {
    @State private var model: AppModel
    /// Seconds of history in the charts.
    @State private var window: TimeInterval = 120

    public init(model: AppModel = AppModel()) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Layout.gridSpacing) {
                gaugeWall
                Divider().overlay(Theme.panelEdge)
                charts
            }
            .padding(Theme.Layout.pagePadding)
        }
        .background(Theme.background)
        .toolbar { toolbar }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Gauges

    private var gaugeMetrics: [MetricID] {
        // Fixed order rather than whatever the registry yields, so the dials do
        // not move around between launches. A gauge you have to hunt for is a
        // gauge you stop glancing at.
        [
            MetricID("disk.bytes.read"),
            MetricID("disk.bytes.written"),
            MetricID("net.bits.in"),
            MetricID("net.bits.out"),
        ].filter { model.descriptor($0) != nil }
    }

    private var gaugeWall: some View {
        LazyVGrid(
            columns: [GridItem(
                .adaptive(
                    minimum: Theme.Layout.gaugeMinimum,
                    maximum: Theme.Layout.gaugeMaximum
                ),
                spacing: Theme.Layout.gridSpacing
            )],
            spacing: Theme.Layout.gridSpacing
        ) {
            ForEach(gaugeMetrics, id: \.self) { metric in
                if let descriptor = model.descriptor(metric) {
                    VStack(spacing: 2) {
                        GaugeView(
                            title: gaugeTitle(descriptor),
                            value: model.latest(metric),
                            fullScale: model.scales[metric]?.fullScale ?? 1,
                            peak: model.scales[metric]?.peak,
                            unit: descriptor.unit,
                            // Needle travel matches the sampling interval, so
                            // it is still moving when the next sample arrives.
                            travelTime: model.interval
                        )
                        // The dial's label, not its value. The readout on the
                        // face already carries the number and its unit, so
                        // repeating it here was the only thing under the dial
                        // — and the label had to come off the face, where at
                        // 130pt across "Network Out" ran into the ticks.
                        Text(gaugeTitle(descriptor).uppercased())
                            .font(.system(
                                size: Theme.Layout.gaugeCaption,
                                weight: .medium,
                                design: .rounded
                            ))
                            .foregroundStyle(Theme.label)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    /// "Disk" + "Read" reads better on a dial as "Disk Read" than as either
    /// alone, since two dials on the wall both say "Read".
    private func gaugeTitle(_ descriptor: MetricDescriptor) -> String {
        descriptor.group == descriptor.name
            ? descriptor.name : "\(descriptor.group) \(descriptor.name)"
    }

    // MARK: - Charts

    /// Which groups get a chart card, in the order they appear.
    ///
    /// Named explicitly rather than derived, for the same reason as the gauge
    /// list: cards that move between launches are cards you have to hunt for.
    /// Deriving it also cannot express the two decisions encoded here — that
    /// disk and network throughput deserve a chart *as well as* a dial, since a
    /// needle cannot tell you a transfer has been running for a minute; and
    /// that "Disk Ops", "Network Packets" and "Memory Paging" are diagnostic
    /// detail that belongs in `monitorctl`, not on a dashboard you glance at.
    private static let chartGroupOrder = [
        "CPU", "CPU Cores", "Memory", "Disk", "Network", "GPU", "Disk Latency",
    ]

    private var chartGroups: [(name: String, metrics: [MetricID])] {
        let available = Dictionary(
            model.groups().map { ($0.name, $0.metrics) },
            uniquingKeysWith: { first, _ in first }
        )
        return Self.chartGroupOrder.compactMap { name in
            guard let metrics = available[name], !metrics.isEmpty else { return nil }
            return (name: name, metrics: metrics)
        }
    }

    private var charts: some View {
        LazyVGrid(
            columns: [GridItem(
                .adaptive(minimum: Theme.Layout.chartMinimum), spacing: Theme.Layout.gridSpacing
            )],
            spacing: Theme.Layout.gridSpacing
        ) {
            ForEach(chartGroups, id: \.name) { group in
                ChartCard(
                    title: group.name,
                    series: group.metrics.compactMap { metric in
                        guard let descriptor = model.descriptor(metric) else { return nil }
                        return (descriptor: descriptor, points: model.points(metric))
                    },
                    window: window,
                    isUnavailable: group.metrics.allSatisfy(model.unavailable.contains)
                )
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("History", selection: $window) {
                Text("1 min").tag(TimeInterval(60))
                Text("2 min").tag(TimeInterval(120))
                Text("5 min").tag(TimeInterval(300))
                // Ten minutes is the ceiling in v1 because that is how much the
                // in-memory buffer holds. Longer ranges need the store.
                Text("10 min").tag(TimeInterval(600))
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem {
            Picker("Rate", selection: $model.interval) {
                Text("0.25 s").tag(TimeInterval(0.25))
                Text("0.5 s").tag(TimeInterval(0.5))
                Text("1 s").tag(TimeInterval(1))
                Text("2 s").tag(TimeInterval(2))
            }
        }
    }
}

#Preview {
    DashboardView()
        .frame(width: 900, height: 700)
}
