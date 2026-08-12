import AppKit
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

    /// Edge length of one dial, and so the height of the gauge wall.
    ///
    /// The dial is square and the wall is one row, so this single number is what
    /// the drag handle moves: pull the rule down by 40 points and the dials get
    /// 40 points taller, which is what makes the handle appear to follow the
    /// pointer rather than to drive something.
    @State private var gaugeSize = Theme.Layout.gaugeDefault
    /// Size when the current drag began, so the gesture reads as an absolute
    /// offset. Accumulating deltas instead would let a drag past the limit build
    /// up credit that has to be dragged back off before the dial moves again.
    @State private var dragOrigin: Double?
    /// Width available to the wall, which is what really limits how big a dial
    /// can get before the row wraps.
    @State private var wallWidth = 0.0

    public init(model: AppModel = AppModel()) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Layout.gridSpacing) {
                gaugeWall
                resizeHandle
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

    /// The largest dial that still fits the whole row in the window.
    ///
    /// Past this the grid wraps and the wall grows by a whole row, which under a
    /// drag reads as the panel jumping rather than resizing. So the drag stops
    /// here instead.
    private var gaugeCeiling: Double {
        guard wallWidth > 0 else { return Theme.Layout.gaugeMaximum }
        let count = Double(max(1, gaugeMetrics.count))
        let fitted = (wallWidth - Theme.Layout.gridSpacing * (count - 1)) / count
        return max(
            Theme.Layout.gaugeMinimum, min(Theme.Layout.gaugeMaximum, fitted)
        )
    }

    private func clamped(_ size: Double) -> Double {
        min(max(Theme.Layout.gaugeMinimum, size), gaugeCeiling)
    }

    private var gaugeWall: some View {
        LazyVGrid(
            columns: [GridItem(
                // Fixed rather than a range: the drag sets the size, and letting
                // the grid pick within a range would fight it.
                .adaptive(minimum: gaugeSize, maximum: gaugeSize),
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
                                size: Theme.Layout.gaugeCaptionSize(forGauge: gaugeSize),
                                weight: .medium,
                                design: .rounded
                            ))
                            .foregroundStyle(Theme.label)
                            .lineLimit(1)
                    }
                }
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: WallWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(WallWidthKey.self) { width in
            wallWidth = width
            // A window narrowed under the current dials has to shrink them, or
            // the row wraps and the wall silently doubles in height.
            gaugeSize = clamped(gaugeSize)
        }
    }

    // MARK: - The handle between the two halves

    /// The rule under the gauges, which drags to resize them.
    ///
    /// It is the boundary between "how fast right now" and "what has been
    /// happening", and how much of the window each deserves depends on what you
    /// are doing: watching a restore run wants big dials, and reading a memory
    /// trend wants the charts. That is a judgement per session, not a constant,
    /// which is why it is a handle and not a number in `Theme`.
    private var resizeHandle: some View {
        Rectangle()
            .fill(Theme.panelEdge)
            .frame(height: 1)
            .frame(height: Theme.Layout.dividerGrab)
            .contentShape(Rectangle())
            .onHover { inside in
                // The pointer is the only thing that says a rule is draggable.
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                // Global, not local. The handle is *inside* what it resizes, so
                // it slides down as the dials grow — and a translation measured
                // against a moving origin reports the pointer's travel minus the
                // handle's own, which damps the drag to roughly half speed and
                // feels like the panel is resisting.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { drag in
                        let origin = dragOrigin ?? gaugeSize
                        dragOrigin = origin
                        gaugeSize = clamped(origin + drag.translation.height)
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
            .accessibilityElement()
            .accessibilityLabel("Gauge size")
            .accessibilityValue(Format.value(gaugeSize, unit: .count))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: gaugeSize = clamped(gaugeSize + 20)
                case .decrement: gaugeSize = clamped(gaugeSize - 20)
                @unknown default: break
                }
            }
    }

    /// Carries the wall's width up from the grid so the drag can be clamped to
    /// what actually fits.
    private struct WallWidthKey: PreferenceKey {
        static let defaultValue = 0.0
        static func reduce(value: inout Double, nextValue: () -> Double) {
            value = max(value, nextValue())
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
