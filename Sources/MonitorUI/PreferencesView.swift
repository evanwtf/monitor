import MonitorCore
import SwiftUI

/// The preferences window, opened with Cmd-, from the app menu.
///
/// Tabbed, with one tab in it. That looks like overkill until the second tab
/// arrives — a `TabView` added later moves every control down by the height of
/// the tab bar, and a preferences window that changes shape between versions is
/// one people have to re-learn. The frame is fixed for the same reason: a
/// settings window is not a document window.
public struct PreferencesView: View {
    @Bindable private var model: AppModel

    public init(model: AppModel) {
        _model = Bindable(model)
    }

    public var body: some View {
        TabView {
            LayoutTab(model: model)
                .tabItem { Label("Layout", systemImage: "square.grid.2x2") }
        }
        .frame(width: 460, height: 520)
    }
}

/// Which metrics get a dial and which get a line, one row per metric.
///
/// Every metric this machine reports is listed, including the ones nothing
/// draws by default. That is the point: the panel ships with a considered
/// layout, and this is where you disagree with it.
struct LayoutTab: View {
    @Bindable var model: AppModel

    /// Rows grouped the way the panel groups them, in the order the panel lays
    /// them out, so the list reads like the window it configures.
    private var sections: [(name: String, metrics: [MetricID])] {
        model.groupOrder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            explanation
            Divider()
            list
            Divider()
            footer
        }
    }

    /// The one thing about this screen that is not obvious from the checkboxes:
    /// a chart is per group, so two ticks in the same group give one card with
    /// two lines rather than two cards.
    private var explanation: some View {
        Text(
            "A gauge is one dial per metric. A chart is one card per group, "
                + "so metrics in the same group share it — tick Network In and "
                + "Network Out and both lines land on the Network chart."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var list: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                header
                ForEach(sections, id: \.name) { section in
                    GridRow {
                        Text(section.name)
                            .font(.headline)
                            .gridCellColumns(3)
                    }
                    .padding(.top, 6)
                    ForEach(section.metrics, id: \.self) { metric in
                        if let descriptor = model.descriptor(metric) {
                            row(descriptor)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var header: some View {
        GridRow {
            // The name column takes the slack, so the two checkbox columns sit
            // against the right edge of the window instead of huddling in the
            // middle with the width of the longest metric name.
            Text("Metric").frame(maxWidth: .infinity, alignment: .leading)
            Text("Gauge")
            Text("Chart")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func row(_ descriptor: MetricDescriptor) -> some View {
        GridRow {
            Text(descriptor.name).frame(maxWidth: .infinity, alignment: .leading)
            LayoutToggle(model: model, descriptor: descriptor, column: .gauge)
                .gridColumnAlignment(.center)
            LayoutToggle(model: model, descriptor: descriptor, column: .chart)
                .gridColumnAlignment(.center)
        }
    }

    private var footer: some View {
        HStack {
            Button("Restore Defaults") { model.restoreDefaultLayout() }
            Spacer()
        }
        .padding(16)
    }
}

/// One checkbox in the grid.
///
/// Its own view rather than a helper returning `some View` because the binding
/// has to read and write the model, and a view that owns the model is the
/// straightforward way to say that.
private struct LayoutToggle: View {
    enum Column: String {
        case gauge, chart
    }

    @Bindable var model: AppModel
    let descriptor: MetricDescriptor
    let column: Column

    var body: some View {
        // The label is hidden but not absent: without it a screen reader reads
        // a column of unnamed checkboxes, and the column heading is rows away.
        Toggle(
            "\(descriptor.group) \(descriptor.name) \(column.rawValue)", isOn: binding
        )
        .labelsHidden()
    }

    private var binding: Binding<Bool> {
        switch column {
        case .gauge:
            Binding(
                get: { model.layout.showsGauge(descriptor.id) },
                set: { model.layout.setGauge($0, for: descriptor.id) }
            )
        case .chart:
            Binding(
                get: { model.layout.showsChart(descriptor.id) },
                set: { model.layout.setChart($0, for: descriptor.id) }
            )
        }
    }
}

#Preview {
    PreferencesView(model: AppModel())
}
