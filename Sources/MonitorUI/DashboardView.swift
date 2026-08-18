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

    /// Size when the current drag began, so the gesture reads as an absolute
    /// offset. Accumulating deltas instead would let a drag past the limit build
    /// up credit that has to be dragged back off before the dial moves again.
    @State private var dragOrigin: Double?
    /// Width available to the wall, which is what really limits how big a dial
    /// can get before the row wraps.
    @State private var wallWidth = 0.0
    /// Whether the toolbar's size popover is showing.
    @State private var showsSizes = false
    /// Which gap is currently showing an insertion line, if any. One value for
    /// the whole panel: exactly one gap can be the target at a time.
    @State private var dropTarget: DropTarget?

    /// Edge length of one dial, and so the height of the gauge wall.
    ///
    /// The dial is square and the wall is one row, so this single number is
    /// what both the drag handle and the popover's first slider move: pull the
    /// rule down by 40 points and the dials get 40 points taller, which is what
    /// makes the handle appear to follow the pointer rather than to drive
    /// something.
    ///
    /// It lives on the model rather than in `@State` so it survives a relaunch.
    /// The write does not happen here: the setter only updates the model, and
    /// whoever ends the gesture calls `commitArrangement`.
    private var gaugeSize: Double {
        get { model.arrangement.gaugeSize }
        nonmutating set { model.arrangement.gaugeSize = newValue }
    }

    public init(model: AppModel = AppModel()) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Layout.gridSpacing) {
                // Both halves are optional now that the layout is chosen in
                // preferences. A wall with no dials on it would otherwise leave
                // a drag handle with nothing to drag.
                if !gaugeMetrics.isEmpty {
                    gaugeWall
                    resizeHandle
                }
                charts(model.performanceGroups, in: .performance)
                // Sensors are a different question from performance. What the
                // machine is doing and how hot it is getting are read at
                // different moments and for different reasons, and mixing them
                // into one grid means hunting for the temperature card among
                // the throughput ones.
                //
                // Drawn whenever this machine has sensors *at all*, not only
                // when the section currently holds a card. Drag the last one up
                // and the section has to stay, or there is no target left to
                // drag it back to. A machine that reports no sensors still
                // shows nothing.
                if model.hasSensors {
                    sectionRule
                    if model.sensorGroups.isEmpty {
                        emptySensorSection
                    } else {
                        charts(model.sensorGroups, in: .sensors)
                    }
                }
            }
            .padding(Theme.Layout.pagePadding)
        }
        .background(Theme.background)
        .toolbar { toolbar }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Gauges

    /// Whichever dials preferences say to draw, in a fixed order — see
    /// `AppModel.gaugeMetrics`.
    private var gaugeMetrics: [MetricID] { model.gaugeMetrics }

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
                    let dial = gaugeTile(metric, descriptor)
                    dial
                        .copyable {
                            CSVExport.text(
                                for: [(descriptor, model.points(metric))], window: window
                            )
                        } rendered: {
                            copyBackground(dial.frame(width: gaugeSize))
                        }
                        .reorderable(
                            .gauge(metric.rawValue), target: $dropTarget, onDrop: dropGauge
                        )
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
            //
            // Deliberately not committed. Narrowing the window is not a request
            // to keep smaller dials forever, so the chosen size stays stored and
            // comes back when there is room for it again. The guard matters as
            // well: assigning during a layout pass invalidates the layout, and
            // an unguarded write would do that on every pass.
            let fitted = clamped(gaugeSize)
            if fitted != gaugeSize { gaugeSize = fitted }
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
                    .onEnded { _ in
                        dragOrigin = nil
                        // Once, here, rather than on every frame of the drag.
                        model.commitArrangement()
                    }
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
                // A discrete step is a whole gesture, unlike a frame of a drag.
                model.commitArrangement()
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

    /// One dial and its caption.
    ///
    /// A function rather than written inline because the copy needs the same
    /// picture a second time — the tile in the wall carries the drag machinery,
    /// and the copy wants only the dial.
    private func gaugeTile(_ metric: MetricID, _ descriptor: MetricDescriptor) -> some View {
        VStack(spacing: 2) {
            GaugeView(
                title: gaugeTitle(descriptor),
                value: model.latest(metric),
                fullScale: model.scales[metric]?.fullScale ?? 1,
                peak: model.scales[metric]?.peak,
                unit: descriptor.unit,
                // Needle travel matches the sampling interval, so it is still
                // moving when the next sample arrives.
                travelTime: model.interval
            )
            // The dial's label, not its value. The readout on the face already
            // carries the number and its unit, so repeating it here was the
            // only thing under the dial — and the label had to come off the
            // face, where at 130pt across "Network Out" ran into the ticks.
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

    /// "Disk" + "Read" reads better on a dial as "Disk Read" than as either
    /// alone, since two dials on the wall both say "Read".
    private func gaugeTitle(_ descriptor: MetricDescriptor) -> String {
        descriptor.group == descriptor.name
            ? descriptor.name : "\(descriptor.group) \(descriptor.name)"
    }

    // MARK: - Charts

    /// The line between the two sections. Deliberately the same rule as the one
    /// under the gauges, minus the drag: one kind of divider on the panel.
    private var sectionRule: some View {
        Rectangle()
            .fill(Theme.panelEdge)
            .frame(height: 1)
            .padding(.vertical, 2)
    }

    private func charts(
        _ groups: [(name: String, metrics: [MetricID])],
        in section: PanelArrangement.ChartSection
    ) -> some View {
        LazyVGrid(
            columns: [GridItem(
                .adaptive(minimum: model.arrangement.chartWidth),
                spacing: Theme.Layout.gridSpacing
            )],
            spacing: Theme.Layout.gridSpacing
        ) {
            ForEach(groups, id: \.name) { group in
                // Read once and used three times — the card, its copied
                // picture and its copied numbers. Reading again for each would
                // let a tick land in between and hand back a CSV that does not
                // match the chart it came from.
                let series = series(of: group)
                let card = ChartCard(
                    title: group.name,
                    series: series,
                    window: window,
                    isUnavailable: group.metrics.allSatisfy(model.unavailable.contains),
                    plotHeight: model.arrangement.chartHeight
                )
                card
                    .copyable {
                        CSVExport.text(for: series, window: window)
                    } rendered: {
                        copyBackground(card.frame(width: model.arrangement.chartWidth))
                    }
                    .reorderable(.chart(group.name), target: $dropTarget) { dragged, on, edge in
                        dropChart(dragged, on: on, edge: edge, in: section)
                    }
            }
        }
    }

    /// The series behind one card, in the order the card draws them.
    private func series(
        of group: (name: String, metrics: [MetricID])
    ) -> [(descriptor: MetricDescriptor, points: [Sample])] {
        group.metrics.compactMap { metric in
            guard let descriptor = model.descriptor(metric) else { return nil }
            return (descriptor: descriptor, points: model.points(metric))
        }
    }

    /// What a copied tile sits on.
    ///
    /// The panel's own background rather than nothing. A card copied
    /// transparent arrives legible on a white document and invisible on a dark
    /// one, and a gauge draws no background at all, so the needle would land on
    /// whatever the reader happened to paste it into.
    private func copyBackground(_ tile: some View) -> some View {
        tile
            .padding(Theme.Layout.pagePadding)
            .background(Theme.background)
    }

    /// What is left of the sensor section once every card has been dragged out
    /// of it: a place to drop one back.
    private var emptySensorSection: some View {
        RoundedRectangle(cornerRadius: Theme.Layout.cardCorner)
            .strokeBorder(
                Theme.panelEdge, style: StrokeStyle(lineWidth: 1, dash: [4, 4])
            )
            .frame(height: 44)
            .overlay(
                Text("Drag a card here")
                    .font(.system(size: Theme.Layout.cardLegend))
                    .foregroundStyle(Theme.label)
            )
            .dropDestination(for: PanelTile.self) { items, _ in
                guard let group = items.first?.chart else { return false }
                model.arrangement.moveGroup(group, to: .sensors)
                model.commitArrangement()
                return true
            }
    }

    // MARK: - Drops

    /// Turns "the half of a tile that was hit" into the neighbour the model's
    /// move wants. Trailing means before whatever comes next, which is the end
    /// of the list when nothing does.
    static func neighbour<T: Equatable>(
        after target: T, in order: [T], edge: DropTarget.Edge
    ) -> T? {
        guard edge == .trailing else { return target }
        guard let index = order.firstIndex(of: target) else { return nil }
        let next = order.index(after: index)
        return next < order.endIndex ? order[next] : nil
    }

    private func dropGauge(_ dragged: PanelTile, on target: PanelTile, edge: DropTarget.Edge) {
        // A chart card dropped on the gauge wall is not a move anybody can make
        // sense of, so it is refused rather than guessed at.
        guard let moved = dragged.gauge, let onto = target.gauge else { return }
        let order = gaugeMetrics
        model.arrangement.moveGauge(
            moved, before: Self.neighbour(after: onto, in: order, edge: edge)
        )
        model.commitArrangement()
    }

    private func dropChart(
        _ dragged: PanelTile, on target: PanelTile, edge: DropTarget.Edge,
        in section: PanelArrangement.ChartSection
    ) {
        guard let moved = dragged.chart, let onto = target.chart else { return }
        let order = model.arrangement.groupOrder(in: section)
        model.arrangement.moveGroup(
            moved, to: section,
            before: Self.neighbour(after: onto, in: order, edge: edge)
        )
        model.commitArrangement()
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
            Button {
                showsSizes.toggle()
            } label: {
                Label("Size", systemImage: "square.resize")
            }
            .help("Resize the gauges and charts")
            .popover(isPresented: $showsSizes, arrowEdge: .bottom) {
                SizePopover(model: model, gaugeCeiling: gaugeCeiling)
            }
        }
        ToolbarItem {
            // The same list preferences offers, not a second one. A rate set
            // here and a rate set there are one setting, and a toolbar that
            // offered 0.25 s while the Sampling tab did not would show an empty
            // picker in preferences whenever it was chosen.
            //
            // The sensor rate is deliberately not here: it is set once and left
            // alone, while this one gets changed while you are watching.
            Picker("Rate", selection: $model.sampling.performance) {
                ForEach(SamplingPreferences.performanceChoices, id: \.self) { seconds in
                    Text(Format.interval(seconds)).tag(seconds)
                }
            }
        }
    }
}

#Preview {
    DashboardView()
        .frame(width: 900, height: 700)
}
