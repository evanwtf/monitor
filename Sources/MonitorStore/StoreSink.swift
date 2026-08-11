import Foundation
import MonitorCore

/// Writes sampled batches into a store, and runs compaction on a slow timer.
///
/// Not used by v1. Nothing in the app constructs this — `monitor` does not even
/// link `MonitorStore`. It exists so the persistence design is settled and
/// tested before the background sampler is built.
///
/// Two things here matter for SSD endurance, and both are why this is a batched
/// sink rather than a write per sample:
///
///  - **One transaction per tick, not one per sample.** Thirty metrics written
///    individually is thirty commits and thirty page writes for about 1.2 kB of
///    data. Batched, it is one.
///  - **Compaction runs every ten minutes, not on the write path.** It rewrites
///    a large part of the table; doing that on every tick would keep the disk
///    busy measuring how busy the disk is.
public actor StoreSink: SampleSink {
    private let store: any HistoryStore
    private let policy: RetentionPolicy
    private let compactionInterval: TimeInterval
    private var lastCompaction: TimeInterval = 0

    public init(
        store: any HistoryStore,
        policy: RetentionPolicy = .week,
        compactionInterval: TimeInterval = 600
    ) {
        self.store = store
        self.policy = policy
        self.compactionInterval = compactionInterval
    }

    public func receive(_ batch: SampleBatch) async {
        do {
            try store.write(batch)
        } catch {
            log.error("history write failed: \(error)")
        }

        guard batch.timestamp - lastCompaction >= compactionInterval else { return }
        lastCompaction = batch.timestamp
        do {
            try store.compact(policy: policy, now: batch.timestamp)
        } catch {
            log.error("history compaction failed: \(error)")
        }
    }
}
