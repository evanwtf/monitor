import Foundation
import MonitorCore
import SQLite3

/// SQLite-backed history.
///
/// SQLite rather than a flat file because two processes touch this database:
/// `monitord` writes and the app reads, at the same time. WAL mode is what
/// makes that safe, and it is set on every connection.
///
/// One table holds both raw samples and rolled-up buckets. A raw sample is
/// simply a bucket with `n = 1`, where min, max and mean are the same number.
/// Compaction rewrites many rows into one and readers never learn the
/// difference — which is the reason a chart can span a week without the query
/// path having two shapes.
public final class SQLiteHistoryStore: HistoryStore, @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    /// `~/Library/Application Support/wtf.evan.monitor/history.sqlite`
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let directory = base.appendingPathComponent("wtf.evan.monitor", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("history.sqlite")
    }

    public init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw StoreError.open(url.path, message: String(cString: sqlite3_errmsg(handle)))
        }
        self.handle = handle

        // WAL lets the app read while the daemon writes. NORMAL sync is the
        // right trade here: a crash can lose the last second of samples, and
        // the alternative is an fsync every second, forever, for data that is
        // deleted within a week anyway.
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA busy_timeout=5000")
        try migrate()
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    // MARK: - Schema

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS samples (
                metric TEXT NOT NULL,
                ts     REAL NOT NULL,
                mean   REAL NOT NULL,
                min    REAL NOT NULL,
                max    REAL NOT NULL,
                n      INTEGER NOT NULL DEFAULT 1,
                PRIMARY KEY (metric, ts)
            ) WITHOUT ROWID
            """
        )
        // Reads are always "this metric, this time range", which the primary
        // key already serves. This index serves compaction, which sweeps by
        // time across every metric.
        try execute("CREATE INDEX IF NOT EXISTS samples_ts ON samples (ts)")
    }

    // MARK: - HistoryStore

    public func write(_ batch: SampleBatch) throws {
        guard !batch.samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        try executeLocked("BEGIN IMMEDIATE")
        do {
            let statement = try prepare(
                """
                INSERT OR REPLACE INTO samples (metric, ts, mean, min, max, n)
                VALUES (?, ?, ?, ?, ?, 1)
                """
            )
            defer { sqlite3_finalize(statement) }

            for sample in batch.samples {
                sqlite3_reset(statement)
                sqlite3_bind_text(statement, 1, sample.metric.rawValue, -1, Self.transient)
                sqlite3_bind_double(statement, 2, sample.timestamp)
                sqlite3_bind_double(statement, 3, sample.value)
                sqlite3_bind_double(statement, 4, sample.value)
                sqlite3_bind_double(statement, 5, sample.value)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            }
            try executeLocked("COMMIT")
        } catch {
            try? executeLocked("ROLLBACK")
            throw error
        }
    }

    public func read(_ query: HistoryQuery) throws -> [MetricID: [Bucket]] {
        guard !query.metrics.isEmpty else { return [:] }
        lock.lock()
        defer { lock.unlock() }

        // Bucketing happens in SQL so a week-wide query returns a chart's worth
        // of rows instead of a week's worth. min/max survive the aggregation,
        // which is what keeps a one-second spike visible at a one-week zoom.
        let statement = try prepare(
            """
            SELECT CAST(ts / ?2 AS INTEGER) * ?2 AS bucket,
                   SUM(mean * n) / SUM(n),
                   MIN(min),
                   MAX(max),
                   SUM(n)
            FROM samples
            WHERE metric = ?1 AND ts >= ?3 AND ts < ?4
            GROUP BY bucket
            ORDER BY bucket
            """
        )
        defer { sqlite3_finalize(statement) }

        var result: [MetricID: [Bucket]] = [:]
        for metric in query.metrics {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, metric.rawValue, -1, Self.transient)
            sqlite3_bind_double(statement, 2, max(query.interval, 0.001))
            sqlite3_bind_double(statement, 3, query.start)
            sqlite3_bind_double(statement, 4, query.end)

            var buckets: [Bucket] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                buckets.append(
                    Bucket(
                        timestamp: sqlite3_column_double(statement, 0),
                        minimum: sqlite3_column_double(statement, 2),
                        maximum: sqlite3_column_double(statement, 3),
                        mean: sqlite3_column_double(statement, 1),
                        count: Int(sqlite3_column_int64(statement, 4))
                    )
                )
            }
            result[metric] = buckets
        }
        return result
    }

    public func compact(policy: RetentionPolicy, now: TimeInterval) throws {
        lock.lock()
        defer { lock.unlock() }

        try executeLocked("BEGIN IMMEDIATE")
        do {
            // Oldest tier first. Each pass only touches rows finer than its
            // target interval, so re-running compaction is a no-op rather than
            // a progressive smearing of the data.
            for tier in policy.tiers.reversed() {
                let cutoff = now - tier.age
                try executeLocked(
                    """
                    INSERT OR REPLACE INTO samples (metric, ts, mean, min, max, n)
                    SELECT metric,
                           CAST(ts / \(tier.interval) AS INTEGER) * \(tier.interval),
                           SUM(mean * n) / SUM(n),
                           MIN(min),
                           MAX(max),
                           SUM(n)
                    FROM samples
                    WHERE ts < \(cutoff) AND n < \(Int(tier.interval))
                    GROUP BY metric, CAST(ts / \(tier.interval) AS INTEGER)
                    HAVING COUNT(*) > 1
                    """
                )
                // Delete the rows just folded in. The replacement row lands on
                // the bucket boundary, so it is excluded by the modulo test and
                // survives this sweep.
                try executeLocked(
                    """
                    DELETE FROM samples
                    WHERE ts < \(cutoff)
                      AND n < \(Int(tier.interval))
                      AND ts != CAST(ts / \(tier.interval) AS INTEGER) * \(tier.interval)
                    """
                )
            }
            try executeLocked("DELETE FROM samples WHERE ts < \(now - policy.horizon)")
            try executeLocked("COMMIT")
        } catch {
            try? executeLocked("ROLLBACK")
            throw error
        }
    }

    public func knownMetrics() throws -> [MetricID] {
        lock.lock()
        defer { lock.unlock() }

        let statement = try prepare("SELECT DISTINCT metric FROM samples ORDER BY metric")
        defer { sqlite3_finalize(statement) }

        var result: [MetricID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            result.append(MetricID(String(cString: text)))
        }
        return result
    }

    /// Size of the database on disk, for the diagnostics panel. Retention is
    /// only a promise until someone checks what it actually costs.
    public func databaseSize() throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }

        let statement = try prepare(
            "SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()"
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    // MARK: - Plumbing

    public enum StoreError: Error, CustomStringConvertible {
        case open(String, message: String)
        case sqlite(String)

        public var description: String {
            switch self {
            case let .open(path, message): "cannot open \(path): \(message)"
            case let .sqlite(message): "sqlite: \(message)"
            }
        }
    }

    /// SQLITE_TRANSIENT: tells SQLite to copy the bound string, since the Swift
    /// buffer does not outlive the call.
    private static let transient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )

    private func lastError() -> StoreError {
        .sqlite(String(cString: sqlite3_errmsg(handle)))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError()
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try executeLocked(sql)
    }

    private func executeLocked(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }
}
