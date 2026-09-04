import Foundation
@testable import MonitorCore
import Testing

struct LogRetentionTests {
    @Test func cadenceFollowsWindow() {
        #expect(LogRetention.oneHour.cadence == 3600)
        #expect(LogRetention.sixHours.cadence == 3600)
        #expect(LogRetention.oneDay.cadence == 86400)
        #expect(LogRetention.sevenDays.cadence == 86400)
        #expect(LogRetention.forever.cadence == 86400)
    }

    @Test func seconds() {
        #expect(LogRetention.oneHour.seconds == 3600)
        #expect(LogRetention.sixHours.seconds == 6 * 3600.0)
        #expect(LogRetention.sevenDays.seconds == 7 * 86400.0)
        #expect(LogRetention.forever.seconds == nil)
    }

    @Test func dailyPeriodIsMidnightLocal() throws {
        let calendar = Calendar.current
        let noon = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 4,
            hour: 10
        )))
        let midnight = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 4
        )))
        let period = LogRetention.period(for: noon.timeIntervalSince1970, cadence: 86400)
        #expect(period == midnight.timeIntervalSince1970)
    }

    @Test func hourlyPeriodIsTopOfHour() throws {
        let calendar = Calendar.current
        let at = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 4,
            hour: 10,
            minute: 23
        )))
        let top = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 4,
            hour: 10
        )))
        let period = LogRetention.period(for: at.timeIntervalSince1970, cadence: 3600)
        #expect(period == top.timeIntervalSince1970)
    }

    @Test func periodReadsBackFromFilename() throws {
        let calendar = Calendar.current
        let day = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 4
        )))
        let parsed = LogRetention.period(from: "monitor-my-host-2026-09-04.csv", cadence: 86400)
        #expect(parsed == day.timeIntervalSince1970)
    }

    @Test func periodReadsBackFromHourlyFilename() throws {
        let calendar = Calendar.current
        let hour = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 4,
            hour: 10
        )))
        let parsed = LogRetention.period(
            from: "monitor-my-host-2026-09-04-10.csv",
            cadence: 3600
        )
        #expect(parsed == hour.timeIntervalSince1970)
    }
}
