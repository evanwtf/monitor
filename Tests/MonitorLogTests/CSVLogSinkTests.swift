import Foundation
import MonitorCore
@testable import MonitorLog
import Testing

struct CSVLogSinkTests {
    private let descriptors = [
        MetricDescriptor(
            id: MetricID("sensor.temperature.cpu"), name: "CPU",
            group: "Temperature", unit: .celsius
        ),
    ]

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("monitord-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writesHeaderAndRows() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = try CSVLogSink(
            directory: dir, hostname: "myhost", retention: .sevenDays, descriptors: descriptors
        )
        let t = Date(timeIntervalSince1970: 1_750_000_000).timeIntervalSince1970
        await sink.receive(SampleBatch(
            timestamp: t,
            values: [MetricID("sensor.temperature.cpu"): 45.0]
        ))
        await sink.close()

        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        #expect(files.count == 1)
        let text = try String(contentsOf: files[0], encoding: .utf8)
        #expect(text
            .hasPrefix("hostname,time_iso8601,time_epoch_ms,sensor.temperature.cpu (°C)\n"))
        #expect(text.contains("myhost,"))
    }

    @Test func rollsOverOnCadenceBoundary() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = try CSVLogSink(
            directory: dir, hostname: "myhost", retention: .sevenDays, descriptors: descriptors
        )
        let day1 = Date(timeIntervalSince1970: 1_750_000_000).timeIntervalSince1970
        let day2 = day1 + 86400
        await sink.receive(SampleBatch(
            timestamp: day1,
            values: [MetricID("sensor.temperature.cpu"): 45.0]
        ))
        await sink.receive(SampleBatch(
            timestamp: day2,
            values: [MetricID("sensor.temperature.cpu"): 46.0]
        ))
        await sink.close()

        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        #expect(files.count == 2)
    }

    @Test func retentionDeletesOldFiles() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = try CSVLogSink(
            directory: dir, hostname: "myhost", retention: .oneHour, descriptors: descriptors
        )
        let t = Date(timeIntervalSince1970: 1_750_000_000).timeIntervalSince1970
        await sink.receive(SampleBatch(
            timestamp: t,
            values: [MetricID("sensor.temperature.cpu"): 45.0]
        ))
        // Two hours later: rolls to a new file, and the sweep deletes the first.
        await sink.receive(SampleBatch(
            timestamp: t + 7200,
            values: [MetricID("sensor.temperature.cpu"): 46.0]
        ))
        await sink.close()

        let files = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        #expect(files.count == 1)
    }
}
