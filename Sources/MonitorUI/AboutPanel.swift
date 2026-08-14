import AppKit
import MonitorCore
import MonitorSources
import SwiftUI

/// The About panel.
///
/// The standard panel with the standard layout, filled in by hand rather than
/// read from the bundle: `swift run monitor` has no `Info.plist`, so the
/// stock panel there says "monitor 1.0 (1)" over a generic icon. Passing the
/// options explicitly makes the bundled build and the development build say
/// the same thing.
///
/// What it says is the machine the readings come from — chip, cores, memory,
/// macOS version. A dashboard screenshot means much less without it, and a
/// monitoring tool is the last place to make somebody go looking elsewhere for
/// what hardware they are on.
public enum About {
    public static let name = "Monitor"
    public static let tagline =
        "A system monitor for macOS, with charts big enough to read."
    public static let repository = "https://github.com/evanwtf/monitor"
    /// The link's text. The scheme adds nothing a reader needs and makes the
    /// line wrap in a 284-point panel.
    static let repositoryLabel = "github.com/evanwtf/monitor"

    /// Opens the panel. Safe to call from a menu item on the main thread.
    @MainActor public static func show() {
        NSApp.orderFrontStandardAboutPanel(options: options())
    }

    @MainActor static func options() -> [NSApplication.AboutPanelOptionKey: Any] {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: name,
            .applicationVersion: MonitorVersion.string,
            .credits: credits(),
        ]
        // The panel prints this in parentheses after the version. An unbundled
        // build has no build number to print, and "(1)" invented from nowhere
        // is worse than nothing.
        options[.version] = ""
        return options
    }

    static func credits() -> NSAttributedString {
        let machine = MachineInfo.current
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.lineSpacing = 2

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(
            string: tagline + "\n\n",
            attributes: [
                .font: body,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: centred,
            ]
        ))
        text.append(NSAttributedString(
            string: machine.hardwareSummary + "\n"
                + "\(machine.model) · macOS \(machine.systemVersion)\n\n",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: NSFont.smallSystemFontSize,
                    weight: .regular
                ),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: centred,
            ]
        ))
        text.append(NSAttributedString(
            string: repositoryLabel,
            attributes: [
                .font: body,
                .link: URL(string: repository) as Any,
                .paragraphStyle: centred,
            ]
        ))
        return text
    }
}

/// Replaces the stock "About monitor" item with one that opens the panel
/// above. The menu title keeps the app's display name, not the executable name
/// the unbundled build would otherwise show.
public struct AboutCommand: Commands {
    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(About.name)") { About.show() }
        }
    }
}
