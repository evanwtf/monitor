# Storage

## v1 writes nothing to disk

The app keeps a ten-minute ring buffer in memory and that is all. Close the
window and the history is gone.

This is a deliberate constraint with a specific reason: **SSD endurance**. A
system monitor is a program that runs all day, every day, for years. That is a
very different profile from an app you open for five minutes, and a careless
design spends real write cycles on data nobody ever reads.

The constraint is enforced structurally, not by convention. `monitor`,
`MonitorUI` and `monitorctl` do not depend on `MonitorStore`, so there is no
code path in the app that can reach the filesystem. See the "Never" section in
`AGENTS.md`.

## The arithmetic, for when persistence arrives

Worth doing properly, because the intuition ("a monitor writing every second
must destroy the drive") turns out to be wrong by two orders of magnitude — but
only if the writes are batched.

About 35 metrics at 2 Hz, each roughly 40 bytes of row: **2.8 kB/s** of logical
data. That is not the number that matters. What matters is what reaches the
flash:

| Design | Per second | Per year | Notes |
|--------|-----------|----------|-------|
| One transaction per sample | ~35 × 4 kB pages = 140 kB/s | **~4.4 TB** | Every commit dirties at least one page plus WAL |
| One transaction per tick (batched) | ~8 kB/s | **~250 GB** | WAL frame plus periodic checkpoint |
| Batched, 1 Hz, 24h horizon | ~4 kB/s | **~125 GB** | |

A 1 TB consumer SSD is typically rated around 600 TBW. The batched design costs
roughly **0.04% of rated endurance per year** — irrelevant. The naive
per-sample design costs about 0.7% per year, which is still survivable but is
25× worse for no benefit whatsoever.

So the rule is not "never write". It is **one transaction per tick, never one
per sample**, and compaction on a slow timer rather than on the write path.
`StoreSink` is built that way and says so.

## Retention: what is already designed

`RetentionPolicy` degrades resolution with age rather than keeping everything:

| Age | Resolution |
|-----|-----------|
| under 1 hour | full (every sample) |
| 1 hour – 1 day | 10-second buckets |
| 1 day – 7 days | 1-minute buckets |
| over 7 days | deleted |

A week of full-resolution samples for 35 metrics is roughly 21 million rows and
answers no question a ten-second average does not. Tiered, the same week is
about 12 MB.

The rolled-up rows keep **min, max and mean**, not just the mean. This is the
part that is easy to get wrong: if aggregation kept only the average, a
one-second spike would vanish as the data aged, and the app would forget
precisely the events it exists to remember. `SQLiteHistoryStoreTests` pins that
a spike survives compaction.

## Why SQLite

Two processes will eventually touch the same history — a background sampler
writing and the app reading. WAL mode makes that safe with no extra machinery.
A flat file would need its own locking, and would have to reinvent range
queries and aggregation that SQL already does in one statement.

Raw samples and rolled-up buckets share one table: a raw sample is a bucket with
`n = 1`. Readers never learn the difference, so a chart spanning a week and a
chart spanning a minute run the same query.
