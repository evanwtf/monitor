import ArgumentParser
@testable import MonitorExporter
import Testing

/// The exporter's front door, like monitord's and monitorctl's. A daemon that
/// booted on `--help` was the bug behind #48; parsing is where that is caught.
@Suite("monitor-exporter arguments")
struct MonitorExporterArgumentTests {
    @Test("defaults are the free port and loopback")
    func defaults() throws {
        let command = try MonitorExporterCommand.parse([])
        #expect(command.bindPort == 9650)
        #expect(command.bindAddress == "127.0.0.1")
    }

    @Test("both flags are accepted with their values")
    func flags() throws {
        let command = try MonitorExporterCommand.parse([
            "--bind-port", "9700", "--bind-address", "0.0.0.0",
        ])
        #expect(command.bindPort == 9700)
        #expect(command.bindAddress == "0.0.0.0")
    }

    @Test("an unrecognised flag is rejected", arguments: ["--nonsense", "--bindport", "-x"])
    func unknownFlagRejected(_ flag: String) {
        #expect(throws: (any Error).self) { try MonitorExporterCommand.parse([flag, "1"]) }
    }

    @Test("port zero is rejected — a scrape target needs a fixed port")
    func portZeroRejected() {
        #expect(throws: (any Error).self) { try MonitorExporterCommand.parse([
            "--bind-port",
            "0",
        ]) }
    }

    @Test("`help` as a bare word becomes --help")
    func helpWord() {
        #expect(MonitorExporter.arguments(rewriting: ["help"]) == ["--help"])
        #expect(
            MonitorExporter.arguments(rewriting: ["--bind-port", "9650"]) == [
                "--bind-port",
                "9650",
            ]
        )
    }
}
