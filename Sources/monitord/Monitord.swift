import ArgumentParser
import Foundation
import MonitorCore
import MonitorLog
import MonitorSources

/// A headless daemon that logs every metric to rotating CSV files.
///
/// The app's ring buffer is a ten-minute live view and dies with the window.
/// This is the long-running counterpart: it samples on the same clock and writes
/// human-readable CSV that other processes can read to correlate performance with
/// temperature or throttling. Run it as a launchd LaunchAgent to log for days.
///
/// The flags are declared, not parsed. The usage text used to be a string
/// literal beside a hand-rolled `firstIndex(of:)` scan, and nothing reached it:
/// `--help` fell through to the start path and booted the daemon, and an
/// unrecognised flag was silently ignored, so `--intrval 0.1` logged at the
/// wrong rate and said nothing (#48). ArgumentParser renders the help from the
/// declarations below, so a flag added here appears in `--help` because there is
/// no second place to add it to.
struct MonitordCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monitord",
        abstract: "Log system metrics to rotating CSV files.",
        discussion: """
        Files are named sensors.<host>.<date>_<time>.csv, one per run, so files \
        from several machines sharing a directory do not clobber, and a restart \
        does not append to the previous run's file. The hostname is lowercased \
        and any character outside [a-z0-9-_] becomes an underscore. Timestamps \
        are ISO8601 in UTC plus epoch millis. Temperatures appear in both \
        degrees C and degrees F.
        """,
        version: MonitorVersion.detailed
    )

    @Option(
        name: .customLong("dir"),
        help: ArgumentHelp("Directory for the CSV files.", valueName: "path")
    )
    var directory: String = MonitordCommand.defaultDirectory.path

    @Option(help: ArgumentHelp("How long to keep files.", valueName: "window"))
    var retention: LogRetention = .oneDay

    @Option(help: ArgumentHelp("Sampling interval in seconds.", valueName: "sec"))
    var interval: Double = 1.0

    /// `~/Library/Logs/monitor`. Resolved here so `--help` prints the real
    /// default rather than a description of it.
    static let defaultDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/monitor", isDirectory: true)

    func validate() throws {
        guard interval > 0 else {
            throw ValidationError("--interval must be greater than zero, not \(interval).")
        }
    }

    func run() throws {
        let directory = URL(fileURLWithPath: directory)
        let sources = SourceRegistry.makeAll()
        let descriptors = sources.flatMap(\.descriptors)
        let hostname = ProcessInfo.processInfo.hostName

        let sink = try CSVLogSink(
            directory: directory, hostname: hostname, retention: retention,
            descriptors: descriptors
        )
        let sampler = Sampler(sources: sources, sinks: [sink], interval: interval)

        // Stop cleanly on SIGINT/SIGTERM so the last rows are flushed to disk.
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signalSource.setEventHandler {
            Task {
                await sampler.stop()
                await sink.close()
                Foundation.exit(0)
            }
        }

        signal(SIGINT, SIG_IGN)
        signalSource.resume()

        Task {
            await sampler.start()
        }

        print(
            "monitord: logging to \(directory.path)"
                + " (retention \(retention.rawValue), interval \(Format.interval(interval)))"
        )
        RunLoop.main.run()
    }
}

/// `--retention 24h` rather than `--retention oneDay`, and the choices in the
/// help come from the enum: a window added to `LogRetention` is offered here
/// without a second edit.
extension LogRetention: ExpressibleByArgument {
    public static var allValueStrings: [String] { allCases.map(\.rawValue) }
}

@main
enum Monitord {
    /// `help` as a bare word, alongside `--help` and `-h`.
    ///
    /// ArgumentParser spells that as a subcommand, and this daemon has none —
    /// but someone who types `monitord help` is asking the same question, and
    /// the answer used to be a daemon starting silently. One rewrite is
    /// cheaper than a subcommand tree for a command with three flags.
    static func main() {
        MonitordCommand.main(arguments(rewriting: Array(CommandLine.arguments.dropFirst())))
    }

    /// Split out from `main` so the rewrite can be tested without running the
    /// daemon — which is the whole difficulty this file exists to remove.
    static func arguments(rewriting arguments: [String]) -> [String] {
        arguments == ["help"] ? ["--help"] : arguments
    }
}
