//
//  MongoResultRebuildTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct MongoResultRebuildTests {
    private func result() -> PluginQueryResult {
        var result = PluginQueryResult(
            columns: ["_id"],
            columnTypeNames: ["Int32"],
            rows: [["1"], ["2"], ["3"]],
            rowsAffected: 0,
            timing: PluginQueryTiming(total: 2, firstRow: 1, server: 0.5),
            columnMeta: [PluginColumnInfo(name: "_id", dataType: "Int32", isPrimaryKey: true)]
        )
        result.rowLocators = [#"{"$numberInt":"1"}"#, nil, #"{"$numberInt":"3"}"#]
        return result
    }

    private func expectCarried(_ rebuilt: PluginQueryResult, from original: PluginQueryResult) {
        #expect(rebuilt.timing == original.timing)
        #expect(rebuilt.columnMeta?.map(\.name) == original.columnMeta?.map(\.name))
    }

    @Test("Setting the affected count or a status keeps the locators, the column metadata and the timing")
    func rebuildsKeepEverything() {
        let original = result()
        let affected = original.withRowsAffected(3)
        #expect(affected.rowsAffected == 3)
        #expect(affected.rowLocators == original.rowLocators)
        expectCarried(affected, from: original)
        let status = original.withStatus("printed")
        #expect(status.statusMessage == "printed")
        #expect(status.rowLocators == original.rowLocators)
        expectCarried(status, from: original)
    }

    @Test("Capping to the row cap cuts the locators with the rows")
    func cappingSlicesLocators() {
        let original = result()
        let capped = original.capped(to: 2)
        #expect(capped.rows.count == 2)
        #expect(capped.isTruncated)
        #expect(capped.rowLocators == [#"{"$numberInt":"1"}"#, nil])
        expectCarried(capped, from: original)
        #expect(original.capped(to: 5).rowLocators == original.rowLocators)
    }

    @Test("Locators that do not pair one to one with the rows are dropped")
    func mismatchedLocators() {
        #expect(result().withRowLocators(["a"]).rowLocators == nil)
        #expect(result().withRowLocators(nil).rowLocators == nil)
        #expect(result().withRowLocators(["a", nil, "c"]).rowLocators == ["a", nil, "c"])
    }
}
