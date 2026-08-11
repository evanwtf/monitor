import MonitorUI
import SwiftUI

/// The app.
///
/// A plain SwiftPM executable, so `swift run monitor` puts a window on screen
/// with no Xcode project in the way. That is the fast development loop. A
/// proper `.app` bundle — icon, Info.plist, signing, a Dock identity — comes
/// with packaging, and does not need to exist to look at a gauge.
@main
struct MonitorApp: App {
    var body: some Scene {
        Window("Monitor", id: "monitor") {
            DashboardView()
                .frame(minWidth: 720, minHeight: 560)
        }
        // Dark only for now. The instrument panel is designed against a dark
        // ground and a light mode is a separate palette, not a toggle.
        .defaultSize(width: 1000, height: 760)
    }
}
