import Foundation
@testable import MonitorCore
import Testing

/// Fixtures at file scope rather than on the suite, so the tests read as the
/// tables they are checking instead of as `Self.this` and `Self.that`.
private let read = MetricDescriptor(
    id: MetricID("disk.bytes.read"), name: "Read", group: "Disk", unit: .bytesPerSecond
)
private let written = MetricDescriptor(
    id: MetricID("disk.bytes.written"), name: "Write", group: "Disk", unit: .bytesPerSecond
)
private let cpu = MetricDescriptor(
    id: MetricID("cpu.total"), name: "Total", group: "CPU", unit: .fraction
)

/// UTC throughout, so the expected strings do not depend on where the test
/// runs. The app passes `.current`.
private let utc = TimeZone(identifier: "UTC")!

private func sample(_ descriptor: MetricDescriptor, _ time: TimeInterval, _ value: Double)
    -> Sample
{
    Sample(metric: descriptor.id, timestamp: time, value: value)
}

private func lines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
}

@Suite("CSVExport")
struct CSVExportTests {
    @Test("Header names every series and its base unit")
    func header() {
        let text = CSVExport.text(
            for: [(read, [sample(read, 100, 1)]), (cpu, [sample(cpu, 100, 0.5)])],
            window: 60, now: 100, timeZone: utc
        )
        #expect(lines(text).first == "Time,Disk Read (B/s),CPU Total (fraction)")
    }

    @Test("A series whose name repeats its group is not doubled")
    func headerWithoutRedundantGroup() {
        let fans = MetricDescriptor(
            id: MetricID("sensors.Fans"), name: "Fans", group: "Fans", unit: .rpm
        )
        let text = CSVExport.text(
            for: [(fans, [sample(fans, 100, 2000)])], window: 60, now: 100, timeZone: utc
        )
        #expect(lines(text).first == "Time,Fans (rpm)")
    }

    @Test("Timestamps are ISO 8601 with an offset")
    func timestamps() {
        let text = CSVExport.text(
            for: [(cpu, [sample(cpu, 0, 0.25)])], window: 60, now: 0, timeZone: utc
        )
        #expect(lines(text)[1].hasPrefix("1970-01-01T00:00:00Z,"))
    }

    @Test("Values are the stored base units, not what the panel shows")
    func rawValues() {
        // 5 MB/s on the dial is 5_000_000 B/s in the buffer, and 50% is 0.5.
        let text = CSVExport.text(
            for: [(read, [sample(read, 0, 5_000_000)]), (cpu, [sample(cpu, 0, 0.5)])],
            window: 60, now: 0, timeZone: utc
        )
        #expect(lines(text)[1].hasSuffix(",5000000.0000,0.5000"))
    }

    @Test("One row per timestamp, with every series on it")
    func rowsAlign() {
        let text = CSVExport.text(
            for: [
                (read, [sample(read, 10, 1), sample(read, 20, 2)]),
                (written, [sample(written, 10, 3), sample(written, 20, 4)]),
            ],
            window: 60, now: 20, timeZone: utc
        )
        let rows = lines(text)
        #expect(rows.count == 4) // header, two rows, trailing newline
        #expect(rows[1].hasSuffix(",1.0000,3.0000"))
        #expect(rows[2].hasSuffix(",2.0000,4.0000"))
    }

    @Test("A series missing a tick leaves its field empty rather than a zero")
    func gaps() {
        // A skipped source is not a source reading zero, and a spreadsheet that
        // cannot tell them apart draws the same lie the panel refuses to draw.
        let text = CSVExport.text(
            for: [
                (read, [sample(read, 10, 1), sample(read, 20, 2)]),
                (written, [sample(written, 20, 4)]),
            ],
            window: 60, now: 20, timeZone: utc
        )
        let rows = lines(text)
        #expect(rows[1].hasSuffix(",1.0000,"))
        #expect(rows[2].hasSuffix(",2.0000,4.0000"))
    }

    @Test("Only the visible window is copied")
    func windowed() {
        // The buffer holds ten minutes; the card shows one. Copying the buffer
        // would hand back data the picture never showed.
        let points = (0..<10).map { sample(cpu, Double($0) * 10, Double($0)) }
        let text = CSVExport.text(for: [(cpu, points)], window: 30, now: 90, timeZone: utc)
        #expect(lines(text).count == 6) // header, 60/70/80/90, trailing newline
    }

    @Test("Rows are ordered oldest first")
    func ordered() {
        let points = [sample(cpu, 30, 3), sample(cpu, 10, 1), sample(cpu, 20, 2)]
        let text = CSVExport.text(for: [(cpu, points)], window: 60, now: 30, timeZone: utc)
        let rows = lines(text)
        #expect(rows[1].hasSuffix(",1.0000"))
        #expect(rows[3].hasSuffix(",3.0000"))
    }

    @Test("A card with nothing in the window copies its header alone")
    func empty() {
        let text = CSVExport.text(for: [(cpu, [])], window: 60, now: 100, timeZone: utc)
        #expect(text == "Time,CPU Total (fraction)\n")
    }

    @Test("A field containing a comma or a quote is quoted")
    func escaping() {
        let odd = MetricDescriptor(
            id: MetricID("x"), name: "In, Out", group: "Net \"work\"", unit: .count
        )
        let text = CSVExport.text(
            for: [(odd, [sample(odd, 0, 1)])], window: 60, now: 0, timeZone: utc
        )
        #expect(lines(text)[0] == "Time,\"Net \"\"work\"\" In, Out (count)\"")
    }

    @Test("Every unit has a base symbol")
    func baseUnits() {
        for unit in [
            MetricUnit.fraction, .bytes, .bytesPerSecond, .bitsPerSecond,
            .operationsPerSecond, .count, .hertz, .celsius, .watts, .rpm, .seconds,
        ] {
            #expect(!Format.baseUnit(unit).isEmpty)
        }
        // The stored value, not the pinned display unit: the panel says MB/s
        // and Mbit/s, and the buffer holds bytes and bits.
        #expect(Format.baseUnit(.bytesPerSecond) == "B/s")
        #expect(Format.baseUnit(.bitsPerSecond) == "bit/s")
    }
}
