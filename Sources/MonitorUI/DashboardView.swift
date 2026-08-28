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
    /// Which tile is zoomed, if any. One value for the whole panel: zoom is a
    /// mode the panel is in, not a property a tile carries, so opening a second
    /// tile closes the first without anybody having to close it.
    ///
    /// `@State`, deliberately. A zoom is a view state and must not outlive the
    /// session or resize anything stored — the tile comes back the size it was.
    @State private var zoomed: PanelTile?
    /// The panel's own size, which is what the zoom is a fraction of.
    @State private var panelSize = CGSize.zero

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
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PanelSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(PanelSizeKey.self) { panelSize = $0 }
        .toolbar { toolbar }
        // The name is drawn by the stamp, which puts the build underneath it.
        // Left in place the system would draw it a second time, beside its own
        // copy.
        .removingWindowTitle()
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        // A sheet rather than a second window: it is temporary, Escape already
        // means dismiss, and nothing has to decide what a stray window does on
        // relaunch. The sampler keeps running underneath.
        .sheet(item: $zoomed) { tile in
            zoom(tile)
        }
    }

    /// Carries the panel's size up so the zoom can be a fraction of it.
    private struct PanelSizeKey: PreferenceKey {
        static let defaultValue = CGSize.zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
            let next = nextValue()
            value = next == .zero ? value : next
        }
    }

    // MARK: - Zoom

    /// The zoomed tile, drawn from the model rather than handed over at
    /// double-click time. A card frozen at the moment it was opened would stop
    /// updating, which is the opposite of what a bigger chart is for.
    @ViewBuilder
    private func zoom(_ tile: PanelTile) -> some View {
        let size = ZoomLayout.size(panel: panelSize)
        ZoomFrame(title: zoomTitle(tile), size: size, close: { zoomed = nil }) {
            switch tile {
            case let .chart(name):
                if let group = zoomedGroup(named: name) {
                    chartCard(group, plotHeight: ZoomLayout.plotHeight(in: size))
                }
            case let .gauge(id):
                let metric = MetricID(id)
                if let descriptor = model.descriptor(metric) {
                    let edge = ZoomLayout.dialEdge(in: size)
                    gaugeTile(metric, descriptor, size: edge)
                        .frame(width: edge)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func zoomTitle(_ tile: PanelTile) -> String {
        switch tile {
        case let .chart(name): name
        case let .gauge(id):
            model.descriptor(MetricID(id)).map(gaugeTitle) ?? id
        }
    }

    /// The group behind a zoomed card, from either section.
    private func zoomedGroup(named name: String) -> (name: String, metrics: [MetricID])? {
        (model.performanceGroups + model.sensorGroups).first { $0.name == name }
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
                    let dial = gaugeTile(metric, descriptor, size: gaugeSize)
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
                        .zoomable(.gauge(metric.rawValue), zoomed: $zoomed)
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
    private func gaugeTile(
        _ metric: MetricID, _ descriptor: MetricDescriptor, size: Double
    ) -> some View {
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
                    size: Theme.Layout.gaugeCaptionSize(forGauge: size),
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
                let card = chartCard(
                    group, series: series, plotHeight: model.arrangement.chartHeight
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
                    .zoomable(.chart(group.name), zoomed: $zoomed)
            }
        }
    }

    /// One card, at whichever plot height the caller wants — the panel's stored
    /// height in the grid, and as much of the sheet as is left in the zoom.
    private func chartCard(
        _ group: (name: String, metrics: [MetricID]),
        series: [(descriptor: MetricDescriptor, points: [Sample])]? = nil,
        plotHeight: Double
    ) -> ChartCard {
        let drawn = series ?? self.series(of: group)
        return ChartCard(
            title: group.name,
            series: drawn,
            window: window,
            isUnavailable: group.metrics.allSatisfy(model.unavailable.contains),
            plotHeight: plotHeight,
            // The metrics the card is *drawing*, not the group's whole
            // membership: switch one direction off and the card stops being a
            // pair.
            mirror: model.charts.mirror(for: drawn.map(\.descriptor)),
            stacked: model.charts.stack(for: drawn.map(\.descriptor)),
            // Nil switches totals off. The gap comes from the model because
            // that is where the sampling clock is.
            totalGap: model.charts.showsTotals ? model.totalGap : nil,
            rotatesTimeLabels: model.charts.rotatesTimeLabels
        )
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

    /// Which build this is, beside the window's title.
    ///
    /// In the title bar rather than the About panel because of how this app
    /// gets used: a monitor is left running for days, and the copy on screen is
    /// very often not the copy just built. The question "am I looking at the
    /// change I just made?" should not cost two clicks to answer.
    ///
    /// **White on black, in the system font.** Not the panel's palette and not
    /// the monospaced face the cards use: this is the one thing in the window
    /// that is not a reading. Everything else on screen is a measurement of the
    /// machine, styled to be scanned; the stamp is a label on the photograph,
    /// and its job is to survive being screenshotted and read back later.
    ///
    /// Which is also why it is black rather than `Theme.panel`, and not left to
    /// the title bar's own styling. The first version borrowed the toolbar's
    /// glass and came out as dark text on a light pill — the lowest contrast
    /// anywhere in the window, on the one element whose entire purpose is to
    /// still be legible in a PNG somebody opens next month.
    ///
    /// `fixedSize` so it is never truncated. A commit clipped to
    /// `v1.4.0-8-gc61738cf · Aug 28 09:3` is worse than no stamp: it looks
    /// complete.
    ///
    /// The app's name sits on top of it and the window's own title is removed,
    /// so the two read as one block — a heading with its build under it —
    /// rather than as a chip parked next to a title that repeats it. A rounded
    /// rectangle rather than a capsule now that it is two lines: a capsule's
    /// ends bow away from a left-aligned second line.
    private var buildStamp: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(MonitorVersion.name)
                .font(.headline)
            Text(BuildStamp.label)
                .font(.caption)
        }
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.black, in: RoundedRectangle(cornerRadius: 7))
        .help("The commit this build came from, and when it was built")
        .accessibilityLabel("\(MonitorVersion.name), build \(BuildStamp.label)")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // macOS 26 wraps every toolbar item in a shared capsule, which put the
        // stamp in the same light pill as the controls opposite — dark text on
        // light glass, and clipped where the capsule ended. The stamp is not a
        // control and should not dress as one, so on 26 it opts out and draws
        // its own background. Earlier releases add no capsule and need no
        // opt-out, which is why this is additive rather than conditional
        // styling.
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { buildStamp }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { buildStamp }
        }
        // `.primaryAction` rather than the default `.automatic`. The controls
        // used to be pushed to the trailing edge by the window's title taking
        // the slack in the middle; with the title removed, `.automatic` packed
        // them up against the stamp on the left. Anchoring them explicitly says
        // what the layout actually depends on, instead of leaning on something
        // that is no longer there.
        ToolbarItem(placement: .primaryAction) {
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
        ToolbarItem(placement: .primaryAction) {
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
        ToolbarItem(placement: .primaryAction) {
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

private extension View {
    /// Drop the window's own title from the toolbar.
    ///
    /// `ToolbarDefaultItemKind.title` arrived in macOS 15 and this package
    /// still builds for 14, where an empty title comes to the same thing on
    /// screen. Either way the `Window` scene keeps its real name, so the Window
    /// menu and the Dock still say what this is.
    @ViewBuilder
    func removingWindowTitle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            navigationTitle("")
        }
    }
}
