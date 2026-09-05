import ArgumentParser
import MonitorCore
@testable import monitorctl
import MonitorSources
import Testing

/// `monitorctl` already rejected an unknown *command* and already printed its
/// usage for a leading `-`. What it did not do was reject an unknown *flag* —
/// the half that changes what gets measured (#48).
@Suite("monitorctl arguments")
struct MonitorctlArgumentTests {
    @Test("The three subcommands are registered under their own names")
    func subcommands() throws {
        #expect(try Monitorctl.parseAsRoot(["list"]) is Monitorctl.List)
        #expect(try Monitorctl.parseAsRoot(["read"]) is Monitorctl.Read)
        #expect(try Monitorctl.parseAsRoot(["watch"]) is Monitorctl.Watch)
    }

    @Test("--version reports the version and the commit")
    func version() {
        #expect(Monitorctl.configuration.version == MonitorVersion.detailed)
    }

    @Test("An unrecognised flag is rejected on every subcommand", arguments: [
        ["list", "--nonsense"], ["read", "--intrval", "1"], ["watch", "--cont", "2"],
        ["read", "-x"],
    ])
    func unknownFlagRejected(_ arguments: [String]) {
        #expect(exitCode(for: arguments) != .success)
    }

    @Test("An unrecognised subcommand is rejected")
    func unknownSubcommandRejected() {
        #expect(exitCode(for: ["frobnicate"]) != .success)
    }

    @Test("--help and --version exit zero", arguments: ["--help", "-h", "--version"])
    func helpAndVersionSucceed(_ flag: String) {
        #expect(exitCode(for: [flag]) == .success)
    }

    @Test("--source is repeatable and defaults to every source")
    func sourcesRepeat() throws {
        let both = try Monitorctl.List.parse(["--source", "cpu", "--source", "gpu"])
        #expect(both.selection.ids == ["cpu", "gpu"])
        #expect(try Monitorctl.List.parse([]).selection.ids.isEmpty)
        #expect(try Monitorctl.List.parse([]).selection.resolve().count == SourceRegistry.allIDs
            .count)
    }

    /// The known-source list in the help and the list validation checks against
    /// are one array, so a source added to the registry cannot be accepted
    /// while going unmentioned, or mentioned while being refused.
    @Test("Every registered source is accepted")
    func everyRegisteredSourceAccepted() throws {
        for id in SourceRegistry.allIDs {
            let command = try Monitorctl.List.parse(["--source", id])
            #expect(command.selection.resolve().count == 1)
        }
    }

    @Test("An unknown source is rejected and named", arguments: ["nope", "cpu2", "CPU"])
    func unknownSourceRejected(_ id: String) {
        #expect(exitCode(for: ["list", "--source", id]) != .success)
    }

    @Test("The help names every registered source")
    func helpNamesEverySource() {
        let help = Monitorctl.List.helpMessage()
        for id in SourceRegistry.allIDs {
            #expect(help.contains(id), "\(id) is missing from the help")
        }
    }

    @Test("The help lists every declared option")
    func helpListsEveryOption() {
        let watch = Monitorctl.Watch.helpMessage()
        for flag in ["--source", "--interval", "--json", "--count", "--help"] {
            #expect(watch.contains(flag), "\(flag) is missing from the watch help")
        }
        let root = Monitorctl.helpMessage()
        for subcommand in ["list", "read", "watch"] {
            #expect(root.contains(subcommand), "\(subcommand) is missing from the help")
        }
    }

    @Test("A non-positive interval is rejected", arguments: ["0", "-1"])
    func nonPositiveIntervalRejected(_ value: String) {
        #expect(exitCode(for: ["read", "--interval", value]) != .success)
    }

    /// `--count 0` used to be accepted and watch forever: the loop compares
    /// `taken < limit`, so a zero limit is indistinguishable from no limit at
    /// the point it is read. Rejecting it is cheaper than teaching the loop.
    @Test("A count below one is rejected", arguments: ["0", "-3"])
    func nonPositiveCountRejected(_ value: String) {
        #expect(exitCode(for: ["watch", "--count", value]) != .success)
    }

    @Test("watch accepts a count and an interval")
    func watchOptions() throws {
        let command = try Monitorctl.Watch.parse([
            "--count",
            "5",
            "--interval",
            "0.25",
            "--json",
        ])
        #expect(command.count == 5)
        #expect(command.sampling.interval == 0.25)
        #expect(command.sampling.json)
    }

    /// What the binary would exit with for these arguments.
    private func exitCode(for arguments: [String]) -> ExitCode {
        do {
            _ = try Monitorctl.parseAsRoot(arguments)
            return .success
        } catch {
            return Monitorctl.exitCode(for: error)
        }
    }
}
