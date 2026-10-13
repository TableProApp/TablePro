//
//  VersionHistoryFormattingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct VersionHistoryFormattingTests {
    @Test("A commit's subtitle separates the author and the revision with a comma")
    func commitSubtitleUsesComma() {
        let entry = VersionHistoryEntry(
            reference: .gitRevision(commit: "abcdef1234", path: "report.sql"),
            summary: "Fix totals",
            author: "Ada"
        )

        #expect(VersionHistoryFormatting.subtitle(for: entry) == "Ada, abcdef1")
        #expect(VersionHistoryFormatting.rowSubtitle(for: entry) == "Ada")
    }

    @Test("The current version's subtitle puts uncommitted changes first, then the author")
    func currentSubtitleUsesComma() {
        let entry = VersionHistoryEntry(reference: .current, author: "Ada", hasUncommittedChanges: true)
        let expected = "\(String(localized: "Uncommitted changes")), Ada"

        #expect(VersionHistoryFormatting.subtitle(for: entry) == expected)
        #expect(VersionHistoryFormatting.rowSubtitle(for: entry) == expected)
    }
}
