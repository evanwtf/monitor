import AppKit
import MonitorCore
import SwiftUI

/// Right-click a card to take it with you.
///
/// A chart on screen is a dead end: to put it in a message, or the numbers
/// behind it in a spreadsheet, the only route was a screenshot. Two items fix
/// both halves — the picture as a PNG, and the samples as CSV.
///
/// This still writes nothing to disk. The pasteboard is somewhere the user
/// asked for it to go, once, by choosing a menu item; `MonitorStore` stays
/// unlinked and the ring buffer stays in memory.
enum CardExport {
    /// Renders a view and puts it on the pasteboard as an image.
    ///
    /// The view is rendered on its own rather than captured from the window, so
    /// what lands on the pasteboard is the card and nothing around it — no
    /// insertion indicator left over from a drag, no slice of the panel behind
    /// it.
    @MainActor
    static func copyImage(_ view: some View) {
        let renderer = ImageRenderer(content: view)
        // The screen's own scale, so the copy is as sharp as what was on it.
        // The default of 1 makes a Retina card look like a photograph of one.
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else {
            log.error("Could not render card for copying")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    static func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

extension View {
    /// The context menu shared by both kinds of tile.
    ///
    /// `rendered` is passed rather than the tile itself because the two are not
    /// the same picture: the tile in the panel is sized by the grid and carries
    /// the drag machinery, and the copy wants a card at its chosen size on the
    /// panel's own background. A gauge in particular draws no background of its
    /// own, and copied without one it would arrive as a needle floating on
    /// whatever the reader pastes it into.
    ///
    /// Both closures run when the item is chosen, not when the menu is built,
    /// so the copy is of the card as it is at that moment.
    func copyable(
        csv: @escaping () -> String,
        @ViewBuilder rendered: @escaping () -> some View
    ) -> some View {
        contextMenu {
            Button {
                CardExport.copyImage(rendered())
            } label: {
                Label("Copy Image", systemImage: "photo")
            }
            Button {
                CardExport.copyText(csv())
            } label: {
                Label("Copy Data", systemImage: "tablecells")
            }
        }
    }
}
