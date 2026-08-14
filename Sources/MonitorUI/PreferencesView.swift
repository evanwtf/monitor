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

    /// Sections the reader has folded away. Empty to start: a list that opens
    /// half closed hides the thing somebody came here to find.
    ///
    /// View state rather than a stored preference. Collapsing is how you get a
    /// long list out of the way while you work on one group, which is a
    /// decision for the next thirty seconds, not for the next month.
    @State private var collapsed: Set<String> = []

    private var list: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                header
                ForEach(sections, id: \.name) { section in
                    sectionHeader(section)
                    if !collapsed.contains(section.name) {
                        ForEach(section.metrics, id: \.self) { metric in
                            if let descriptor = model.descriptor(metric) {
                                row(descriptor)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    /// A group's heading: a disclosure triangle, the group name, and the two
    /// checkboxes that set every metric under it.
    ///
    /// The section checkbox is the same control as the row checkboxes, one
    /// level up — tick it and the whole column turns on, untick it and the
    /// whole column turns off. It draws itself as mixed when the rows disagree,
    /// which is what makes a collapsed section still readable: a dash rather
    /// than a tick says "some of these", so folding a group away does not hide
    /// what state it is in.
    private func sectionHeader(
        _ section: (name: String, metrics: [MetricID])
    ) -> some View {
        GridRow {
            Button {
                toggleCollapsed(section.name)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        // Rotated rather than swapped for a second symbol, so
                        // the triangle turns instead of blinking.
                        .rotationEffect(.degrees(collapsed.contains(section.name) ? -90 : 0))
                    Text(section.name).font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(section.name) metrics")
            .accessibilityValue(collapsed.contains(section.name) ? "collapsed" : "expanded")

            SectionToggle(model: model, section: section.name,
                          metrics: section.metrics, column: .gauge)
                .gridColumnAlignment(.center)
            SectionToggle(model: model, section: section.name,
                          metrics: section.metrics, column: .chart)
                .gridColumnAlignment(.center)
        }
        .padding(.top, 6)
    }

    private func toggleCollapsed(_ section: String) {
        if collapsed.contains(section) {
            collapsed.remove(section)
        } else {
            collapsed.insert(section)
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
private struct LayoutToggle: View {
    @Bindable var model: AppModel
    let descriptor: MetricDescriptor
    let column: AppModel.LayoutColumn

    var body: some View {
        // The label is hidden but not absent: without it a screen reader reads
        // a column of unnamed checkboxes, and the column heading is rows away.
        Toggle(
            "\(descriptor.group) \(descriptor.name) \(column.rawValue)",
            isOn: model.binding(column, for: descriptor.id)
        )
        .labelsHidden()
    }
}

/// The checkbox in a section heading, which sets every metric under it.
///
/// `Toggle(_:sources:isOn:)` rather than a `Bool` of our own: given the row
/// bindings it derives the three states itself — on when all agree, off when
/// none, mixed when they disagree — and writes to all of them when clicked.
/// A hand-rolled version would have to keep a separate flag in step with the
/// rows, which is the bug this API exists to remove.
private struct SectionToggle: View {
    /// One row's binding, wrapped because `sources:` takes a collection of
    /// elements and a key path to the binding inside each.
    private struct Entry {
        let binding: Binding<Bool>
    }

    @Bindable var model: AppModel
    let section: String
    let metrics: [MetricID]
    let column: AppModel.LayoutColumn

    var body: some View {
        Toggle(
            "All \(section) \(column.rawValue)s",
            sources: metrics.map { Entry(binding: model.binding(column, for: $0)) },
            isOn: \.binding
        )
        .labelsHidden()
    }
}

#Preview {
    PreferencesView(model: AppModel())
}
