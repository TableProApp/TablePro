//
//  DateFormattingServiceTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("DateFormattingService column-type buckets")
@MainActor
struct DateFormattingServiceTests {
    @Test("DATE column with datetime wire value formats to date only")
    func dateColumnStripsTime() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let result = DateFormattingService.shared.format(
            dateString: "2024-03-01 12:34:56",
            columnType: .date(rawType: "DATE")
        )
        #expect(result == "2024-03-01")
    }

    @Test("DATETIME column keeps date and time")
    func datetimeColumnKeepsBothComponents() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let result = DateFormattingService.shared.format(
            dateString: "2024-03-01 12:34:56",
            columnType: .datetime(rawType: "DATETIME")
        )
        #expect(result == "2024-03-01 12:34:56")
    }

    @Test("TIME column emits time only")
    func timeColumnEmitsTimeOnly() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let result = DateFormattingService.shared.format(
            dateString: "2024-03-01 12:34:56",
            columnType: .timestamp(rawType: "TIME")
        )
        #expect(result == "12:34:56")
    }

    @Test("TIMETZ column emits time only")
    func timetzColumnEmitsTimeOnly() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let result = DateFormattingService.shared.format(
            dateString: "2024-03-01 12:34:56",
            columnType: .timestamp(rawType: "TIMETZ")
        )
        #expect(result == "12:34:56")
    }

    @Test("nil columnType falls back to datetime formatter")
    func nilColumnTypeFallsBackToDatetime() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let result = DateFormattingService.shared.format(
            dateString: "2024-03-01 12:34:56",
            columnType: nil
        )
        #expect(result == "2024-03-01 12:34:56")
    }

    @Test("unparseable input returns nil")
    func unparseableReturnsNil() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let result = DateFormattingService.shared.format(
            dateString: "not-a-date",
            columnType: .date(rawType: "DATE")
        )
        #expect(result == nil)
    }

    @Test("same wire value formats differently for DATE vs DATETIME (cache bucket isolation)")
    func cacheBucketIsolation() {
        DateFormattingService.shared.updateFormat(.iso8601)
        let wire = "2024-03-01 09:00:00"
        let asDatetime = DateFormattingService.shared.format(
            dateString: wire,
            columnType: .datetime(rawType: "DATETIME")
        )
        let asDate = DateFormattingService.shared.format(
            dateString: wire,
            columnType: .date(rawType: "DATE")
        )
        #expect(asDatetime == "2024-03-01 09:00:00")
        #expect(asDate == "2024-03-01")
    }
}
