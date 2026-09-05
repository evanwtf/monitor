import Foundation
import MonitorCore

/// Writes sampled batches to rotating CSV files.
///
/// One file per day, named `sensors.<host>.<date>.log` so files from several
/// machines sharing a directory do not clobber. The header is written when a
/// file is first created; a file reopened after a restart appends without
/// repeating it.
///
/// Retention deletes whole files whose period is older than the window. It runs
/// on a slow timer, not on every write, so a log that runs for days does not pay
/// for a directory listing every second.
public actor CSVLogSink: SampleSink {
    private let directory: URL
    private let hostname: String
    private let retention: LogRetention
    private let descriptors: [MetricDescriptor]
    private var current: (period: TimeInterval, handle: FileHandle)?
    private var lastSweep: TimeInterval = 0
    private let sweepInterval: TimeInterval = 60

    public init(
        directory: URL,
        hostname: String,
        retention: LogRetention,
        descriptors: [MetricDescriptor]
    ) throws {
        self.directory = directory
        self.hostname = hostname
        self.retention = retention
        self.descriptors = descriptors
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    public func receive(_ batch: SampleBatch) async {
        let period = LogRetention.period(for: batch.timestamp)
        if current?.period != period {
            closeCurrent()
            open(period: period)
        }
        guard let handle = current?.handle else { return }
        let values = Dictionary(
            batch.samples.map { ($0.metric, $0.value) },
            uniquingKeysWith: { _, latest in latest }
        )
        let line = CSVLogFormat.row(
            hostname: hostname, timestamp: batch.timestamp,
            values: values, descriptors: descriptors
        )
        try? handle.write(contentsOf: Data(line.utf8))
        if batch.timestamp - lastSweep >= sweepInterval {
            lastSweep = batch.timestamp
            sweep(now: batch.timestamp)
        }
    }

    /// Flush and close the open file. Call on shutdown so the last rows are not
    /// left in the OS page cache.
    public func close() {
        closeCurrent()
    }

    // MARK: - Files

    private func open(period: TimeInterval) {
        let url = directory.appendingPathComponent(filename(for: period))
        let isNew = !FileManager.default.fileExists(atPath: url.path)
        if isNew {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        try? handle.seekToEnd()
        if isNew {
            let header = CSVLogFormat.header(hostname: hostname, descriptors: descriptors) + "\n"
            try? handle.write(contentsOf: Data(header.utf8))
        }
        current = (period, handle)
    }

    private func closeCurrent() {
        try? current?.handle.close()
        current = nil
    }

    private func filename(for period: TimeInterval) -> String {
        let date = Date(timeIntervalSince1970: period)
        let formatter = DateFormatter()
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy_MM_dd"
        return "sensors.\(sanitized(hostname)).\(formatter.string(from: date)).log"
    }

    private func sweep(now: TimeInterval) {
        guard let window = retention.seconds else { return }
        let cutoff = now - window
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for file in files
            where file.lastPathComponent.hasPrefix("sensors.\(sanitized(hostname)).")
        {
            guard let period = LogRetention.period(from: file.lastPathComponent)
            else { continue }
            if period + 86400 <= cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func sanitized(_ hostname: String) -> String {
        hostname
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }
}
