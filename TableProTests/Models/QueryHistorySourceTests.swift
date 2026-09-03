//
//  QueryHistorySourceTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("QueryHistorySource")
struct QueryHistorySourceTests {
    @Test("raw values are stable, because they are written to disk")
    func rawValuesAreStable() {
        #expect(QueryHistorySource.editor.rawValue == "editor")
        #expect(QueryHistorySource.explain.rawValue == "explain")
        #expect(QueryHistorySource.tableBrowse.rawValue == "table_browse")
        #expect(QueryHistorySource.rowEdit.rawValue == "row_edit")
        #expect(QueryHistorySource.structureDDL.rawValue == "structure_ddl")
        #expect(QueryHistorySource.dataImport.rawValue == "import")
        #expect(QueryHistorySource.mcp.rawValue == "mcp")
    }

    @Test("the default filter hides app-generated statements")
    func userAuthoredExcludesGeneratedSources() {
        #expect(QueryHistorySource.userAuthored.contains(.editor))
        #expect(QueryHistorySource.userAuthored.contains(.explain))
        #expect(QueryHistorySource.userAuthored.contains(.tableBrowse) == false)
        #expect(QueryHistorySource.userAuthored.contains(.rowEdit) == false)
        #expect(QueryHistorySource.userAuthored.contains(.structureDDL) == false)
        #expect(QueryHistorySource.userAuthored.contains(.dataImport) == false)
        #expect(QueryHistorySource.userAuthored.contains(.mcp) == false)
    }

    @Test("every source is presentable")
    func everySourceHasDisplayNameAndSymbol() {
        for source in QueryHistorySource.allCases {
            #expect(source.displayName.isEmpty == false)
            #expect(source.symbolName.isEmpty == false)
        }
    }
}

@Suite("QueryHistoryStatementType")
struct QueryHistoryStatementTypeTests {
    @Test("reads classify as select")
    func readsClassifyAsSelect() {
        for query in ["SELECT 1", "select 1", "SHOW TABLES", "WITH t AS (SELECT 1) SELECT * FROM t", "EXPLAIN SELECT 1"] {
            #expect(QueryHistoryStatementType.classify(query) == .select, "\(query)")
        }
    }

    @Test("writes classify by verb")
    func writesClassifyByVerb() {
        #expect(QueryHistoryStatementType.classify("INSERT INTO t VALUES (1)") == .insert)
        #expect(QueryHistoryStatementType.classify("UPDATE t SET a = 1") == .update)
        #expect(QueryHistoryStatementType.classify("DELETE FROM t") == .delete)
        #expect(QueryHistoryStatementType.classify("TRUNCATE TABLE t") == .delete)
    }

    @Test("structure changes classify as ddl")
    func structureChangesClassifyAsDdl() {
        for query in ["CREATE TABLE t (a INT)", "ALTER TABLE t ADD COLUMN b INT", "DROP TABLE t", "GRANT SELECT ON t TO r"] {
            #expect(QueryHistoryStatementType.classify(query) == .ddl, "\(query)")
        }
    }

    @Test("leading comments do not hide the verb")
    func leadingCommentsAreIgnored() {
        #expect(QueryHistoryStatementType.classify("-- note\nSELECT 1") == .select)
        #expect(QueryHistoryStatementType.classify("/* block */ DELETE FROM t") == .delete)
    }

    @Test("unrecognized text classifies as other rather than guessing")
    func unknownClassifiesAsOther() {
        #expect(QueryHistoryStatementType.classify("") == .other)
        #expect(QueryHistoryStatementType.classify("db.users.find({})") == .other)
    }
}

@Suite("QueryHistoryFilter")
struct QueryHistoryFilterTests {
    @Test("an empty source set matches nothing")
    func emptySourcesMatchNothing() {
        #expect(QueryHistoryFilter(scope: .all, sources: []).matchesNothing)
    }

    @Test("an empty allowlist matches nothing")
    func emptyAllowlistMatchesNothing() {
        #expect(QueryHistoryFilter(scope: .all, allowedConnectionIds: []).matchesNothing)
    }

    @Test("an inverted date window matches nothing")
    func invertedWindowMatchesNothing() {
        let now = Date()
        let filter = QueryHistoryFilter(scope: .all, since: now, until: now.addingTimeInterval(-60))
        #expect(filter.matchesNothing)
    }

    @Test("a plain filter matches something")
    func defaultFilterMatchesSomething() {
        #expect(QueryHistoryFilter(scope: .all).matchesNothing == false)
    }
}

@Suite("HistoryDateRange")
struct HistoryDateRangeTests {
    @Test("all time has no lower bound")
    func allTimeHasNoSince() {
        #expect(HistoryDateRange.all.since() == nil)
    }

    @Test("every other range has a lower bound in the past")
    func rangesLookBackwards() {
        let reference = Date()
        for range in HistoryDateRange.allCases where range != .all {
            let since = range.since(from: reference)
            #expect(since != nil, "\(range)")
            #expect((since ?? reference) <= reference, "\(range)")
        }
    }

    @Test("ranges widen in order")
    func rangesWidenInOrder() {
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        let hour = HistoryDateRange.lastHour.since(from: reference) ?? reference
        let week = HistoryDateRange.week.since(from: reference) ?? reference
        let month = HistoryDateRange.month.since(from: reference) ?? reference
        #expect(month < week)
        #expect(week < hour)
    }

    /// A stored filter that was "Everything" before `script` existed must not start hiding it.
    @Test("The previous all-sources selection widens to include the new source")
    func everythingMigratesToIncludeScript() {
        let before: Set<QueryHistorySource> = [
            .editor, .explain, .tableBrowse, .rowEdit, .structureDDL, .dataImport, .mcp
        ]
        #expect(QueryHistorySource.migratingStoredSelection(before) == Set(QueryHistorySource.allCases))
    }

    @Test("A custom selection is left exactly as the user set it")
    func customSelectionIsUntouched() {
        let custom: Set<QueryHistorySource> = [.editor, .mcp]
        #expect(QueryHistorySource.migratingStoredSelection(custom) == custom)

        let userAuthored = QueryHistorySource.userAuthored
        #expect(QueryHistorySource.migratingStoredSelection(userAuthored) == userAuthored)
    }
}
