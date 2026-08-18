import MonitorCore
import SwiftUI

/// The three sliders behind the toolbar's Size button.
///
/// In the toolbar rather than in preferences for the same reason the sampling
/// rate is: you change it while watching. Judging a dial size in one window
/// while dragging a slider in another is guesswork.
///
/// A popover rather than three toolbar controls, because the toolbar already
/// carries the history and rate pickers and three sliders beside them would
/// leave no room for either.
///
/// **Gauges are one number** — the dial is square, so its edge length is its
/// size. **Charts are two**, width and height independently, because a wide
/// short card and a tall narrow one answer different questions and neither is a
/// scaled copy of the other.
struct SizePopover: View {
    @Bindable var model: AppModel
    /// The largest dial that still fits one row in this window, which only the
    /// dashboard can know. The slider stops there rather than at the model's
    /// ceiling, or the wall wraps and doubles in height.
    var gaugeCeiling: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            slider(
                "Gauges",
                value: $model.arrangement.gaugeSize,
                range: PanelSize.gauge.minimum...max(PanelSize.gauge.minimum, gaugeCeiling)
            )
            slider(
                "Chart width",
                value: $model.arrangement.chartWidth,
                range: PanelSize.chartWidth.bounds
            )
            slider(
                "Chart height",
                value: $model.arrangement.chartHeight,
                range: PanelSize.chartHeight.bounds
            )
            Divider()
            Button("Reset to defaults") { model.restoreDefaultArrangement() }
                .controlSize(.small)
        }
        .padding(14)
        .frame(width: 230)
    }

    /// Every slider here writes on release, never during the drag.
    ///
    /// The binding updates the panel live — it has to, or the slider is useless
    /// — but the write to `UserDefaults` waits for `onEditingChanged` to go
    /// false. A slider dragged across its travel fires on every frame, and
    /// persisting each one turns a single decision into a few hundred writes.
    /// That is the whole argument in `docs/storage.md`, at a smaller scale.
    private func slider(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded())) pt")
                    .foregroundStyle(.secondary)
                    // A width that does not change as the digits do, so the
                    // label beside it cannot twitch while you drag.
                    .monospacedDigit()
            }
            .font(.system(size: 11))
            Slider(value: value, in: range) { editing in
                if !editing { model.commitArrangement() }
            }
            .controlSize(.small)
        }
    }
}
