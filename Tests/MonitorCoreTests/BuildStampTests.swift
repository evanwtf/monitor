import Foundation
@testable import MonitorCore
import Testing

@Suite("BuildStamp")
struct BuildStampTests {
    private static let utc = TimeZone(identifier: "UTC")!

    @Test("The commit is stamped, not left blank")
    func commitIsStamped() {
        // The plugin runs before every build, so a blank here means it did not
        // run at all — which is silent otherwise, since the title bar would
        // simply show nothing where the commit belongs.
        #expect(!BuildStamp.commit.isEmpty)
    }

    @Test("Both facts land on one line")
    func labelCarriesBoth() {
        let built = Date(timeIntervalSince1970: 1_756_374_720)
        let label = BuildStamp.label(
            commit: "v1.4.0-4-ga8e8631",
            built: built,
            timeZone: Self.utc
        )
        #expect(label == "v1.4.0-4-ga8e8631 · Aug 28 09:52")
    }

    @Test("An unreadable build time leaves the commit alone")
    func missingBuildTime() {
        // Half an answer beats a stand-in date that looks like the other half —
        // the same rule the sources follow when a read fails.
        #expect(BuildStamp.label(commit: "abc1234", built: nil) == "abc1234")
    }

    @Test("The build time carries the date, not only the clock")
    func dateNotJustTime() {
        // A bare time is ambiguous the moment the window has been open
        // overnight, which is exactly when somebody checks whether the app on
        // screen is the one they just built.
        let label = BuildStamp.builtLabel(
            Date(timeIntervalSince1970: 1_756_374_720), timeZone: Self.utc
        )
        #expect(label == "Aug 28 09:52")
    }

    @Test("A build time is found for this very binary")
    func readsItsOwnDate() throws {
        // The test bundle is an executable too, so the runtime half is
        // exercised rather than only the formatting around it.
        let built = try #require(BuildStamp.built)
        #expect(built.timeIntervalSince1970 > 1_700_000_000)
        #expect(built <= Date())
    }
}
