import AppKit
import MonitorUI
import SwiftUI

/// The app.
///
/// A plain SwiftPM executable, so `swift run monitor` puts a window on screen
/// with no Xcode project in the way. That is the fast development loop.
/// `Scripts/make-app.sh` wraps the same binary in a real `.app` bundle when one
/// is wanted; the delegate below makes the unbundled build behave like an app
/// in the meantime.
@main
struct MonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// One model behind both scenes. The preferences window edits the same
    /// layout the dashboard draws from, so a checkbox takes effect while you
    /// are looking at it rather than at the next launch.
    @State private var model = AppModel()

    var body: some Scene {
        Window("Monitor", id: "monitor") {
            DashboardView(model: model)
                .frame(minWidth: 720, minHeight: 560)
        }
        // Dark only for now. The instrument panel is designed against a dark
        // ground and a light mode is a separate palette, not a toggle.
        .defaultSize(width: 1000, height: 760)
        .commands { AboutCommand() }

        // A `Settings` scene rather than a window of our own: it is what puts
        // "Settings…" in the app menu under Cmd-, where people look for it.
        Settings {
            PreferencesView(model: model)
        }
    }
}

/// Claims a foreground identity for the process.
///
/// macOS decides what an app *is* from its bundle, and a bare SwiftPM
/// executable has no bundle: it launches as an accessory, which means no Dock
/// icon, no Cmd-Tab entry, no menu bar and therefore no Cmd-Q. The window
/// appears behind whatever is already open and the only way to stop it is to
/// interrupt the terminal that started it.
///
/// Asking for `.regular` at launch buys all of that back without a bundle. The
/// call is harmless in a bundled build, where the policy is already regular.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// One window and no documents: closing it means "I am done watching", so
    /// the process should not outlive it. Without this a closed window leaves a
    /// sampler running with nothing to draw on.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}
