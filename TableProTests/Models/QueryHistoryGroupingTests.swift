//
//  QueryHistoryGroupingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("QueryHistoryGrouping")
struct QueryHistoryGroupingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private func makeEntry(at date: Date, query: String = "SELECT 1") -> QueryHistoryEntry {
        QueryHistoryEntry(
            query: query,
            connectionId: UUID(),
            databaseName: "db",
            databaseType: .postgresql,
            source: .editor,
            executedAt: date,
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true
        )
    }

    @Test("entries from the same day land in one section")
    func sameDayGroupsTogether() {
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            makeEntry(at: reference, query: "SELECT a"),
            makeEntry(at: reference.addingTimeInterval(-3_600), query: "SELECT b")
        ]

        let sections = QueryHistoryGrouping.byDay(entries, calendar: calendar)
        #expect(sections.count == 1)
        #expect(sections.first?.entries.count == 2)
    }

    @Test("sections keep the order the entries arrived in")
    func sectionsPreserveArrivalOrder() {
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = today.addingTimeInterval(-86_400)
        let entries = [
            makeEntry(at: today, query: "SELECT today"),
            makeEntry(at: yesterday, query: "SELECT yesterday")
        ]

        let sections = QueryHistoryGrouping.byDay(entries, calendar: calendar)
        #expect(sections.count == 2)
        #expect(sections.first?.entries.first?.query == "SELECT today")
        #expect(sections.last?.entries.first?.query == "SELECT yesterday")
    }

    @Test("no entries produce no sections")
    func emptyInputProducesNoSections() {
        #expect(QueryHistoryGrouping.byDay([], calendar: calendar).isEmpty)
    }

    @Test("today and yesterday are named, older days are dated")
    func sectionTitles() {
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        let today = calendar.startOfDay(for: reference)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let older = calendar.date(byAdding: .day, value: -5, to: today) ?? today

        #expect(
            QueryHistoryGrouping.title(for: today, calendar: calendar, relativeTo: reference)
                == String(localized: "Today")
        )
        #expect(
            QueryHistoryGrouping.title(for: yesterday, calendar: calendar, relativeTo: reference)
                == String(localized: "Yesterday")
        )

        let olderTitle = QueryHistoryGrouping.title(for: older, calendar: calendar, relativeTo: reference)
        #expect(olderTitle != String(localized: "Today"))
        #expect(olderTitle != String(localized: "Yesterday"))
        #expect(olderTitle.isEmpty == false)
    }

    @Test("grouping does not drop or duplicate entries")
    func groupingIsLossless() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = (0 ..< 30).map { index in
            makeEntry(at: base.addingTimeInterval(-Double(index) * 7_200), query: "SELECT \(index)")
        }

        let sections = QueryHistoryGrouping.byDay(entries, calendar: calendar)
        let regrouped = sections.flatMap(\.entries)
        #expect(regrouped.count == entries.count)
        #expect(Set(regrouped.map(\.id)) == Set(entries.map(\.id)))
    }
}
