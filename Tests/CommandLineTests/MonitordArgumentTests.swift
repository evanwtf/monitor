import ArgumentParser
import Foundation
import MonitorCore
@testable import monitord
import Testing

/// `monitord --help` used to start the daemon. So did `-h`, `help`, `--version`
/// and `--nonsense`: every one of them fell through to the start path, wrote a
/// CSV and printed nothing (#48). The daemon itself was never broken, which is
/// why nothing else caught it — these tests cover the front door.
@Suite("monitord arguments")
struct MonitordArgumentTests {
    @Test("Defaults match what the help prints")
    func defaults() throws {
        let command = try MonitordCommand.parse([])
        #expect(command.interval == 1.0)
        #expect(command.retention == .oneDay)
        #expect(command.directory == MonitordCommand.defaultDirectory.path)
    }

    @Test("Every flag is accepted with its value")
    func flags() throws {
        let command = try MonitordCommand.parse([
            "--dir", "/tmp/logs", "--retention", "7d", "--interval", "0.5",
        ])
        #expect(command.directory == "/tmp/logs")
        #expect(command.retention == .sevenDays)
        #expect(command.interval == 0.5)
    }

    /// The row from the issue that mattered most. `--intrval 0.1` used to start
    /// a daemon at the default rate and say nothing, so the CSV recorded one
    /// interval while its operator believed another.
    @Test("An unrecognised flag is rejected, not ignored", arguments: [
        "--nonsense", "--intrval", "--retension", "-x",
    ])
    func unknownFlagRejected(_ flag: String) {
        #expect(throws: (any Error).self) { try MonitordCommand.parse([flag, "1"]) }
    }

    @Test("A flag missing its value is rejected")
    func missingValueRejected() {
        #expect(throws: (any Error).self) { try MonitordCommand.parse(["--interval"]) }
    }

    @Test("An unparseable value is rejected", arguments: [
        ["--interval", "soon"], ["--retention", "bogus"], ["--retention", "forevre"],
    ])
    func badValueRejected(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try MonitordCommand.parse(arguments) }
    }

    /// Zero would divide the sampling clock by nothing; a negative interval
    /// schedules a tick in the past. Neither is caught by type conversion.
    @Test("A non-positive interval is rejected", arguments: ["0", "-1", "-0.5"])
    func nonPositiveIntervalRejected(_ value: String) {
        #expect(throws: (any Error).self) { try MonitordCommand.parse(["--interval", value]) }
    }

    /// The issue asks for exit codes as well as output: `monitord --version` is
    /// the natural way a script asks "is this build new enough", and a non-zero
    /// status there fails the script that is only trying to look.
    @Test("--help and --version exit zero", arguments: ["--help", "-h", "--version"])
    func helpAndVersionSucceed(_ flag: String) {
        #expect(exitCode(for: [flag]) == .success)
    }

    @Test("A rejected flag exits non-zero", arguments: [
        ["--nonsense"], ["--interval"], ["--interval", "0"], ["--retention", "bogus"],
    ])
    func rejectionExitsNonZero(_ arguments: [String]) {
        #expect(exitCode(for: arguments) != .success)
    }

    /// What the binary would exit with for these arguments.
    private func exitCode(for arguments: [String]) -> ExitCode {
        do {
            _ = try MonitordCommand.parse(arguments)
            return .success
        } catch {
            return MonitordCommand.exitCode(for: error)
        }
    }

    @Test("`help` as a bare word reaches the same place")
    func bareHelpWordIsRewritten() {
        #expect(Monitord.arguments(rewriting: ["help"]) == ["--help"])
        #expect(Monitord.arguments(rewriting: []) == [])
        #expect(Monitord.arguments(rewriting: ["help", "--dir", "/tmp"]) == [
            "help", "--dir", "/tmp",
        ])
    }

    /// The point of declaring the flags rather than writing the usage by hand:
    /// there is no second place to add a flag to, so help cannot fall behind.
    @Test("The help lists every declared option")
    func helpListsEveryOption() {
        let help = MonitordCommand.helpMessage()
        for flag in ["--dir", "--retention", "--interval", "--version", "--help"] {
            #expect(help.contains(flag), "\(flag) is missing from the help")
        }
    }

    @Test("The help prints the real defaults, not a description of them")
    func helpCarriesDefaults() {
        let help = MonitordCommand.helpMessage()
        #expect(help.contains(MonitordCommand.defaultDirectory.path))
        #expect(help.contains("default: 24h"))
    }

    /// A window added to LogRetention must appear in `--help` without a second
    /// edit. The old usage string listed them by hand and was already one
    /// literal away from lying.
    @Test("Retention choices come from the enum")
    func retentionChoicesAreDerived() {
        #expect(LogRetention.allValueStrings == LogRetention.allCases.map(\.rawValue))
        let help = MonitordCommand.helpMessage()
        for window in LogRetention.allCases {
            #expect(
                help.contains(window.rawValue),
                "\(window.rawValue) is missing from the help"
            )
        }
    }

    @Test("--version reports the version and the commit")
    func versionIsDetailed() {
        #expect(MonitorVersion.detailed.hasPrefix(MonitorVersion.string))
        #expect(MonitorVersion.detailed.contains(BuildStamp.commit))
        #expect(MonitordCommand.configuration.version == MonitorVersion.detailed)
    }
}
