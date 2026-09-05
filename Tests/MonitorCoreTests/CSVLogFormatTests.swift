import Foundation
@testable import MonitorCore
import Testing

struct CSVLogFormatTests {
    private let descriptors = [
        MetricDescriptor(
            id: MetricID("sensor.temperature.cpu"), name: "CPU",
            group: "Temperature", unit: .celsius
        ),
        MetricDescriptor(
            id: MetricID("sensor.fan.1.speed"), name: "Fan 1",
            group: "Fans", unit: .rpm
        ),
    ]

    @Test func headerListsHostnameTimeAndMetrics() {
        let header = CSVLogFormat.header(hostname: "myhost", descriptors: descriptors)
        #expect(
            header
                == "hostname,time_iso8601,time_epoch_ms,sensor.temperature.cpu (°C),sensor.temperature.cpu (°F),sensor.fan.1.speed (rpm)"
        )
    }

    @Test func rowMapsValuesAndLeavesMissingEmpty() {
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000).timeIntervalSince1970
        let values: [MetricID: Double] = [MetricID("sensor.temperature.cpu"): 45.25]
        let row = CSVLogFormat.row(
            hostname: "myhost", timestamp: timestamp, values: values, descriptors: descriptors
        )
        let fields = row.split(separator: ",", omittingEmptySubsequences: false)
        #expect(fields[0] == "myhost")
        #expect(fields[2] == "1750000000000")
        #expect(fields[3] == "45.25") // °C
        #expect(fields[4] == "113.45") // °F = 45.25 × 9/5 + 32
        #expect(fields[5] == "") // fan missed this tick
    }

    @Test func rpmIsAWholeNumber() {
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000).timeIntervalSince1970
        let values: [MetricID: Double] = [MetricID("sensor.fan.1.speed"): 1234.7]
        let row = CSVLogFormat.row(
            hostname: "myhost", timestamp: timestamp, values: values, descriptors: descriptors
        )
        let fields = row.split(separator: ",", omittingEmptySubsequences: false)
        #expect(fields[3] == "") // temperature missed this tick
        #expect(fields[5] == "1235") // rounded to a whole RPM
    }

    @Test func iso8601IsUTC() {
        #expect(CSVLogFormat.iso8601(0) == "1970-01-01T00:00:00Z")
    }
}
