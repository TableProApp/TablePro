//
//  QueryTabVersionSubjectTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct QueryTabVersionSubjectTests {
    @Test("A history tab for a query tab round-trips the tab it shows")
    func queryTabSubjectRoundTrips() throws {
        let subject = VersionHistorySubject.queryTab(id: UUID())
        let tab = PersistedTab(
            id: UUID(),
            title: "History: Query 1",
            query: "",
            tabType: .versionHistory,
            tableName: nil,
            versionHistorySubject: subject
        )

        let decoded = try JSONDecoder().decode(PersistedTab.self, from: try JSONEncoder().encode(tab))

        #expect(decoded.tabType == .versionHistory)
        #expect(decoded.versionHistorySubject == subject)
    }

    @Test("The saved query and file subjects keep the encoding older builds wrote")
    func existingSubjectsDecodeUnchanged() throws {
        let favoriteId = UUID()
        let json = Data(#"{"savedQuery":{"id":"\#(favoriteId.uuidString)"}}"#.utf8)
        #expect(try JSONDecoder().decode(VersionHistorySubject.self, from: json) == .savedQuery(id: favoriteId))
    }

    @Test("The notice names both the count and the days")
    func noticeNamesCountAndDays() {
        let text = VersionHistoryFormatting.noticeText(.keepsRecentVersions(count: 50, days: 7))
        #expect(text == String(
            format: String(localized: "Keeps up to %1$d versions from the last %2$d days on this Mac."),
            50,
            7
        ))
    }

    @Test("A Revert To row leads with the date, then names a run")
    func menuTitleLeadsWithTheDate() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let dateText = date.formatted(date: .abbreviated, time: .shortened)
        let run = VersionHistoryEntry(reference: .tabVersion(id: 1), summary: String(localized: "Run"), date: date)
        let idle = VersionHistoryEntry(reference: .tabVersion(id: 2), summary: nil, date: date)

        #expect(VersionHistoryFormatting.menuTitle(for: run) == String(
            format: String(localized: "%1$@ (%2$@)"),
            dateText,
            String(localized: "Run")
        ))
        #expect(VersionHistoryFormatting.menuTitle(for: idle) == dateText)
    }

    @Test("A closed tab's message tells the reader how to get the history back")
    func closedTabMessage() {
        #expect(VersionHistoryError.tabClosed.errorDescription
            == String(localized: "This tab is closed. Reopen it to see its history."))
    }
}
