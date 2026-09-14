import ArgumentParser
import Foundation
import MonitorCore
import MonitorSources

/// A headless daemon that serves the macOS SMC and GPU sensors as Prometheus
/// metrics on GET /metrics, for a Prometheus server to scrape.
///
/// It reads the sensors at scrape time, so the scrape interval is the sampling
/// rate — there is no interval to configure. It exports only what node_exporter
/// cannot read on macOS: SMC temperatures, fans and power, and the GPU. A sensor
/// this machine does not have produces no series rather than a zero.
///
/// The flags are declared, not parsed — the reason set out in monitord's
/// Monitord.swift (#48): a hand-rolled scan let `--help` reach the start path.
struct MonitorExporterCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monitor-exporter",
        abstract: "Serve macOS SMC and GPU sensors as Prometheus metrics.",
        discussion: """
        Exposes GET /metrics for a Prometheus server to scrape. Exports only \
        what node_exporter does not read on macOS: SMC temperatures, fans and \
        power, and the GPU. A sensor this machine does not have produces no \
        series rather than a zero.
        """,
        version: MonitorVersion.detailed
    )

    @Option(
        name: .customLong("bind-port"),
        help: ArgumentHelp("TCP port to listen on.", valueName: "port")
    )
    var bindPort: UInt16 = 9650

    @Option(
        name: .customLong("bind-address"),
        help: ArgumentHelp("Address to bind. 0.0.0.0 exposes it to the LAN.", valueName: "addr")
    )
    var bindAddress: String = "127.0.0.1"

    /// The sources this exports: the macOS gap node_exporter cannot read.
    static let gapSourceIDs = ["sensors", "gpu"]

    func validate() throws {
        guard bindPort > 0 else {
            throw ValidationError("--bind-port must be a fixed port, not 0.")
        }
    }

    func run() throws {
        let sources = SourceRegistry.make(ids: Self.gapSourceIDs)
        let handler = MetricsHandler(sources: sources)
        let server = try MetricsServer(host: bindAddress, port: bindPort) {
            handler.exposition()
        }
        server.start()
        // A CLI whose job is output: monitord prints its startup line the same
        // way. The server runs on its own queue, so hold the process open.
        print("monitor-exporter: serving /metrics on \(bindAddress):\(bindPort)")
        RunLoop.main.run()
    }
}

@main
enum MonitorExporter {
    static func main() {
        MonitorExporterCommand
            .main(arguments(rewriting: Array(CommandLine.arguments.dropFirst())))
    }

    /// `help` as a bare word, alongside `--help` — the same rewrite as monitord.
    static func arguments(rewriting arguments: [String]) -> [String] {
        arguments == ["help"] ? ["--help"] : arguments
    }
}
