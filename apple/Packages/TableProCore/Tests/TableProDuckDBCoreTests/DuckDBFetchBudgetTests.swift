import Foundation
import TableProDuckDBCore
import Testing

@Test func aResultPastFiveMillionRowsIsReadWholeWithoutALimit() {
    var budget = DuckDBFetchBudget(limit: .max)
    var kept = 0
    for _ in 0..<5_860 {
        kept += budget.take(2_048)
    }
    #expect(kept == 12_001_280)
    #expect(!budget.isExceeded)
}

@Test func aResultOfExactlyTheLimitIsNotTruncated() {
    var budget = DuckDBFetchBudget(limit: 4_096)
    #expect(budget.take(2_048) == 2_048)
    #expect(budget.take(2_048) == 2_048)
    #expect(!budget.isExceeded)
    #expect(budget.take(0) == 0)
    #expect(!budget.isExceeded)
}

@Test func theFirstRowPastTheLimitStopsTheRead() {
    var budget = DuckDBFetchBudget(limit: 1_000)
    #expect(budget.take(2_048) == 1_000)
    #expect(budget.isExceeded)
    #expect(budget.kept == 1_000)
    #expect(budget.take(2_048) == 0)
}

@Test func aLimitInsideALaterChunkKeepsOnlyItsHead() {
    var budget = DuckDBFetchBudget(limit: 3_000)
    #expect(budget.take(2_048) == 2_048)
    #expect(!budget.isExceeded)
    #expect(budget.take(2_048) == 952)
    #expect(budget.isExceeded)
}

@Test func anUnfinishedStatementIsDroppedOnlyOutsideATransaction() {
    #expect(DuckDBUnreadRows.abandonWhenIdle.abandons { true })
    #expect(!DuckDBUnreadRows.abandonWhenIdle.abandons { false })
    #expect(DuckDBUnreadRows.abandon.abandons { false })
    #expect(!DuckDBUnreadRows.drain.abandons { true })
}

@Test func theSessionIsNotProbedWhenTheAnswerCannotChangeTheOutcome() {
    var probes = 0
    _ = DuckDBUnreadRows.drain.abandons { probes += 1; return true }
    _ = DuckDBUnreadRows.abandon.abandons { probes += 1; return true }
    #expect(probes == 0)
}

@Test func theRenderingConnectionTakesOnlyTheSettingsThatDiffer() {
    let statements = DuckDBRenderSettings.assignments(
        from: ["TimeZone": "UTC", "Calendar": "gregorian"],
        to: ["TimeZone": "Asia/Tokyo", "Calendar": "gregorian"]
    )
    #expect(statements == ["SET TimeZone = 'Asia/Tokyo'"])
}

@Test func aSettingTheSessionDoesNotReportIsLeftAlone() {
    #expect(DuckDBRenderSettings.assignments(from: [:], to: [:]).isEmpty)
    #expect(DuckDBRenderSettings.assignments(from: ["TimeZone": "UTC"], to: [:]).isEmpty)
}

@Test func aSettingValueIsQuotedAsALiteral() {
    let statements = DuckDBRenderSettings.assignments(from: [:], to: ["TimeZone": "it's"])
    #expect(statements == ["SET TimeZone = 'it''s'"])
}
