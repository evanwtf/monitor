import Foundation
import MonitorCore
import MonitorLog
import MonitorSources

// A headless daemon that logs every metric to rotating CSV files.
//
// The app's ring buffer is a ten-minute live view and dies with the window.
// This is the long-running counterpart: it samples on the same clock and writes
// human-readable CSV that other processes can read to correlate performance with
// temperature or throttling. Run it as a launchd LaunchAgent to log for days.

let usage = """
monitord — log system metrics to rotating CSV files.

USAGE
  monitord [options]

OPTIONS
  --dir <path>         directory for the CSV files (default: ~/Library/Logs/monitor)
  --retention <window> how long to keep files: 1h, 6h, 24h, 48h, 3d, 5d, 7d, 14d, 30d, forever
                       (default: 7d)
  --interval <sec>     sampling interval (default 1.0)

NOTES
  Files are named sensors.<host>.<date>.log, one per day, so files from several
  machines sharing a directory do not clobber. Timestamps are ISO8601 in UTC
  plus epoch millis. Temperatures appear in both degrees C and degrees F.
"""

let arguments = Array(CommandLine.arguments.dropFirst())

func value(for flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag),
          index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let directory = value(for: "--dir").map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/monitor", isDirectory: true)
let retention = value(for: "--retention").flatMap(LogRetention.init(rawValue:)) ?? .sevenDays
let interval = value(for: "--interval").flatMap(Double.init) ?? 1.0

let sources = SourceRegistry.makeAll()
let descriptors = sources.flatMap(\.descriptors)
let hostname = ProcessInfo.processInfo.hostName

let sink = try CSVLogSink(
    directory: directory, hostname: hostname, retention: retention, descriptors: descriptors
)
let sampler = Sampler(sources: sources, sinks: [sink], interval: interval)

/// Stop cleanly on SIGINT/SIGTERM so the last rows are flushed to disk.
let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signalSource.setEventHandler {
    Task {
        await sampler.stop()
        await sink.close()
        exit(0)
    }
}

signal(SIGINT, SIG_IGN)
signalSource.resume()

Task {
    await sampler.start()
}

print(
    "monitord: logging to \(directory.path) (retention \(retention.rawValue), interval \(Format.interval(interval)))"
)
RunLoop.main.run()
