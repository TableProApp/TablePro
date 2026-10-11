import Foundation
import Testing

@testable import TableProImport

@Suite("Saved query ledger and rules")
struct SavedQueryLedgerTests {
    private let scope = UUID()
    private let otherScope = UUID()

    private func entry(_ name: String, _ sql: String, keyword: String? = nil, scope: UUID? = nil) -> SavedQueryLedger.Entry {
        SavedQueryLedger.Entry(name: name, sql: sql, keyword: keyword, connectionId: scope)
    }

    @Test("Same scope, name and SQL is already saved, ignoring name case and surrounding whitespace")
    func sameContentIsAlreadySaved() {
        let ledger = SavedQueryLedger([entry("Daily users", "select 1", scope: scope)])
        #expect(ledger.verdict(name: " daily USERS ", sql: "\n select 1 \n", keyword: nil, scope: scope) == .alreadySaved)
    }

    @Test("The same content in another scope is not saved there")
    func otherScopeIsNotSaved() {
        let ledger = SavedQueryLedger([entry("Daily users", "select 1", scope: scope)])
        #expect(ledger.verdict(name: "Daily users", sql: "select 1", keyword: nil, scope: otherScope)
            == .insert(keyword: nil, dropped: nil, nameExists: false))
        #expect(ledger.verdict(name: "Daily users", sql: "select 1", keyword: nil, scope: nil)
            == .insert(keyword: nil, dropped: nil, nameExists: false))
    }

    @Test("Same name with different SQL imports alongside with a note")
    func sameNameDifferentSQL() {
        let ledger = SavedQueryLedger([entry("Daily users", "select 1", scope: scope)])
        #expect(ledger.verdict(name: "daily users", sql: "select 2", keyword: nil, scope: scope)
            == .insert(keyword: nil, dropped: nil, nameExists: true))
    }

    @Test("A global keyword blocks the same keyword everywhere")
    func globalKeywordBlocksScoped() {
        let ledger = SavedQueryLedger([entry("A", "select 1", keyword: "dau")])
        #expect(ledger.verdict(name: "B", sql: "select 2", keyword: "dau", scope: scope)
            == .insert(keyword: nil, dropped: .inUse("dau"), nameExists: false))
        #expect(ledger.verdict(name: "B", sql: "select 2", keyword: "dau", scope: nil)
            == .insert(keyword: nil, dropped: .inUse("dau"), nameExists: false))
    }

    @Test("A scoped keyword blocks its own scope and global, not another connection")
    func scopedKeywordBlocksOwnScopeAndGlobal() {
        let ledger = SavedQueryLedger([entry("A", "select 1", keyword: "dau", scope: scope)])
        #expect(ledger.verdict(name: "B", sql: "select 2", keyword: "dau", scope: scope)
            == .insert(keyword: nil, dropped: .inUse("dau"), nameExists: false))
        #expect(ledger.verdict(name: "B", sql: "select 2", keyword: "dau", scope: nil)
            == .insert(keyword: nil, dropped: .inUse("dau"), nameExists: false))
        #expect(ledger.verdict(name: "B", sql: "select 2", keyword: "dau", scope: otherScope)
            == .insert(keyword: "dau", dropped: nil, nameExists: false))
    }

    @Test("Keywords compare case-sensitively, like the storage query")
    func keywordsAreCaseSensitive() {
        let ledger = SavedQueryLedger([entry("A", "select 1", keyword: "dau")])
        #expect(ledger.verdict(name: "B", sql: "select 2", keyword: "DAU", scope: nil)
            == .insert(keyword: "DAU", dropped: nil, nameExists: false))
    }

    @Test("A keyword with whitespace inside is dropped as invalid")
    func invalidKeywordIsDropped() {
        let ledger = SavedQueryLedger([])
        #expect(ledger.verdict(name: "B", sql: "select 2", keyword: "kw two", scope: nil)
            == .insert(keyword: nil, dropped: .invalid("kw two"), nameExists: false))
        #expect(ledger.verdict(name: "B", sql: "select 2", keyword: "kw\ttab", scope: nil)
            == .insert(keyword: nil, dropped: .invalid("kw\ttab"), nameExists: false))
    }

    @Test("A keyword is trimmed and an empty one means none")
    func keywordIsTrimmed() {
        let ledger = SavedQueryLedger([])
        #expect(ledger.verdict(name: "B", sql: "select 2", keyword: "  dau ", scope: nil)
            == .insert(keyword: "dau", dropped: nil, nameExists: false))
        #expect(ledger.verdict(name: "B", sql: "select 2", keyword: "   ", scope: nil)
            == .insert(keyword: nil, dropped: nil, nameExists: false))
    }

    @Test("Size over the sync limit is checked before anything else")
    func sizeIsCheckedFirst() {
        let sql = String(repeating: "x", count: SavedQuerySize.maximumSyncableByteCount)
        let ledger = SavedQueryLedger([entry("Huge", sql)])
        #expect(ledger.verdict(name: "Huge", sql: sql, keyword: nil, scope: nil) == .tooLarge(byteCount: sql.utf8.count + 4))
    }

    @Test("A recorded entry is seen by later verdicts")
    func recordedEntriesCount() {
        var ledger = SavedQueryLedger([])
        ledger.record(entry("A", "select 1", keyword: "dau", scope: scope))
        #expect(ledger.verdict(name: "A", sql: "select 1", keyword: nil, scope: scope) == .alreadySaved)
        #expect(ledger.verdict(name: "B", sql: "select 2", keyword: "dau", scope: scope)
            == .insert(keyword: nil, dropped: .inUse("dau"), nameExists: false))
    }

    @Test("An imported keyword that shadows an SQL keyword is dropped, whatever its case")
    func sqlKeywordIsDropped() {
        let ledger = SavedQueryLedger([])
        #expect(ledger.verdict(name: "Wipe", sql: "DROP TABLE users", keyword: "Select", scope: nil)
            == .insert(keyword: nil, dropped: .invalid("Select"), nameExists: false))
        #expect(ledger.verdict(name: "Users", sql: "select 1", keyword: "sel", scope: nil)
            == .insert(keyword: "sel", dropped: nil, nameExists: false))
    }

    @Test("Byte count is UTF-8 over name, SQL and keyword")
    func byteCountIsUTF8() {
        #expect(SavedQuerySize.byteCount(name: "é", sql: "select", keyword: "k") == 2 + 6 + 1)
        #expect(SavedQuerySize.byteCount(name: "a", sql: "b", keyword: nil) == 2)
    }

    @Test("Keyword helpers trim and reject whitespace")
    func keywordHelpers() {
        #expect(SavedQueryKeyword.normalized(nil) == nil)
        #expect(SavedQueryKeyword.normalized(" \n") == nil)
        #expect(SavedQueryKeyword.normalized(" sel ") == "sel")
        #expect(SavedQueryKeyword.isValid("sel"))
        #expect(!SavedQueryKeyword.isValid("se l"))
        #expect(!SavedQueryKeyword.isValid("sel\n"))
    }

    @Test("A folder holds records of its own scope, and a global folder holds anything")
    func scopeRule() {
        #expect(SavedQueryScopeRule.folder(nil, canHold: scope))
        #expect(SavedQueryScopeRule.folder(nil, canHold: nil))
        #expect(SavedQueryScopeRule.folder(scope, canHold: scope))
        #expect(!SavedQueryScopeRule.folder(scope, canHold: nil))
        #expect(!SavedQueryScopeRule.folder(scope, canHold: otherScope))
    }

    @Test("A derived name comes from the first comment or line, capped at 50 characters")
    func derivedName() {
        #expect(SavedQueryName.derived(from: "\n  -- Active users  \nselect 1") == "Active users")
        #expect(SavedQueryName.derived(from: "--\nselect 1") == "select 1")
        #expect(SavedQueryName.derived(from: "  select * from orders") == "select * from orders")
        #expect(SavedQueryName.derived(from: String(repeating: "a", count: 80)) == String(repeating: "a", count: 50))
        #expect(SavedQueryName.derived(from: " \n\r\n") == "Untitled")
    }
}
