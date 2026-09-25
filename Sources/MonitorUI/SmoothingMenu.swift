import MonitorCore
import SwiftUI

/// The Smoothing and Window sections of a chart card's right-click menu.
///
/// On the card rather than in a preferences tab, because the choice is per
/// card and the card is where you notice you want it.
///
/// **Two flat sections, not a submenu.** The card redraws on every tick, and
/// the right-click menu is rebuilt with it. SwiftUI updates top-level items in
/// place, so Copy Image and Copy Data stay put, but it replaces a nested
/// `Menu` outright: an open Smoothing submenu blinked out and back once a
/// tick. One section per choice — the method, then the window — also keeps the
/// menu to seven items rather than a method-by-window grid of ten.
struct SmoothingMenu: View {
    /// What the card draws now: the stored choice after stacking has had its
    /// say. The ticks go here, so the menu agrees with the tag on the card.
    let current: Smoothing?
    /// Whether the card is stacked. Only the mean can smooth a stack.
    let isStacked: Bool
    /// Stores a choice. Nil draws the card raw.
    let choose: (Smoothing?) -> Void

    var body: some View {
        Section("Smoothing") {
            Toggle("Off", isOn: tick(current == nil) { choose(nil) })
            ForEach(SmoothingMethod.allCases, id: \.self) { method in
                let blocked = isStacked && !method.isStackable
                Toggle(
                    blocked ? "\(title(method)) (not stacked)" : title(method),
                    isOn: tick(current?.method == method) {
                        // Keep the window when switching method: somebody
                        // comparing average and median wants the same span.
                        let window = current?.window ?? Smoothing.defaultWindow
                        choose(Smoothing(method: method, window: window))
                    }
                )
                .disabled(blocked)
            }
        }
        Section("Window") {
            ForEach(Smoothing.windows, id: \.self) { window in
                Toggle(Format.span(window), isOn: tick(current?.window == window) {
                    if let current { choose(Smoothing(method: current.method, window: window)) }
                })
                // A window with nothing to smooth is not a choice.
                .disabled(current == nil)
            }
        }
    }

    private func title(_ method: SmoothingMethod) -> String {
        switch method {
        case .mean: "Average"
        case .median: "Median"
        case .band: "Min–max band"
        }
    }

    /// A tick that runs `select` when chosen. Choosing the ticked item again
    /// does nothing: a menu item that switches itself off reads as a mis-click.
    private func tick(_ isOn: Bool, select: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { isOn }, set: { if $0 { select() } })
    }
}
