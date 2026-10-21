//
//  ImportRowWritingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ImportRowWritingTests {
    private func column(_ name: String, primary: Bool = false) -> ColumnInfo {
        TestFixtures.makeColumnInfo(name: name, isPrimaryKey: primary)
    }

    private func index(
        _ name: String,
        _ columns: [String],
        unique: Bool = true,
        primary: Bool = false,
        whereClause: String? = nil,
        expressions: [String]? = nil
    ) -> IndexInfo {
        IndexInfo(
            name: name, columns: columns, isUnique: unique, isPrimary: primary, type: "BTREE",
            whereClause: whereClause, expressions: expressions
        )
    }

    @Test("The primary key comes first, then each unique index over plain columns")
    func keyOptions() {
        let columns = [column("id", primary: true), column("email"), column("tenant"), column("code")]
        let keys = ImportMatchKey.options(columns: columns, indexes: [
            index("PRIMARY", ["id"], primary: true),
            index("people_email", ["EMAIL"]),
            index("people_tenant_code", ["tenant", "code"]),
            index("people_code", ["code"], unique: false),
            index("people_active_email", ["email"], whereClause: "active"),
            index("people_lower_email", ["lower(email)"], expressions: ["lower(email)"]),
        ])

        #expect(keys.map { $0.columns } == [["id"], ["email"], ["tenant", "code"]])
        #expect(keys.map { $0.indexName } == [nil, "people_email", "people_tenant_code"])
        #expect(keys.first?.isPrimaryKey == true)
    }

    @Test("An index column resolves to its exact spelling before a case-folded one")
    func exactSpellingWins() {
        let columns = [column("ID"), column("id", primary: true), column("Email")]
        let keys = ImportMatchKey.options(columns: columns, indexes: [
            index("pkey", ["id"], primary: true),
            index("email_key", ["email"]),
            index("upper_key", ["Id"]),
        ])
        #expect(keys.map { $0.columns } == [["id"], ["Email"]])
    }

    @Test("Columns flagged as the primary key stand in when no index says so")
    func primaryKeyFromColumns() {
        let keys = ImportMatchKey.options(columns: [column("a", primary: true), column("b", primary: true)], indexes: [])
        #expect(keys == [ImportMatchKey(indexName: nil, columns: ["a", "b"])])
    }

    @Test("A unique index over the primary key's columns is not offered twice")
    func duplicateOfPrimaryKeyIsDropped() {
        let keys = ImportMatchKey.options(
            columns: [column("id", primary: true)],
            indexes: [index("id_unique", ["id"])]
        )
        #expect(keys.count == 1)
    }

    @Test("A table with no key offers nothing to match on")
    func noKey() {
        #expect(ImportMatchKey.options(columns: [column("a")], indexes: [index("a_idx", ["a"], unique: false)]).isEmpty)
    }

    @Test("Insert needs no key")
    func insertHasNoProblem() {
        #expect(ImportRowWritingProblem.of(mode: .insert, key: nil, mappedColumns: ["a"]) == nil)
    }

    @Test("A matching mode needs a key, mapped, and an update needs a column outside it")
    func matchingProblems() {
        let key = ImportMatchKey(indexName: nil, columns: ["tenant", "id"])
        #expect(ImportRowWritingProblem.of(mode: .update, key: nil, mappedColumns: ["a"]) == .noKey)
        #expect(ImportRowWritingProblem.of(mode: .upsert, key: key, mappedColumns: ["id", "name"])
            == .unmappedKeyColumns(["tenant"]))
        #expect(ImportRowWritingProblem.of(mode: .update, key: key, mappedColumns: ["id", "tenant"]) == .nothingToUpdate)
        #expect(ImportRowWritingProblem.of(mode: .upsert, key: key, mappedColumns: ["id", "tenant"]) == .nothingToUpdate)
        #expect(ImportRowWritingProblem.of(mode: .insertSkippingExisting, key: key, mappedColumns: ["id", "tenant"]) == nil)
        #expect(ImportRowWritingProblem.of(mode: .update, key: key, mappedColumns: ["id", "tenant", "name"]) == nil)
    }

    @Test("A matching mode reports matched, updated, inserted and skipped rows")
    func matchingSummary() {
        var tally = ImportRowTally(mode: .update)
        tally.updated = 9_500
        tally.unmatched = 500

        #expect(tally.summaryLines(failed: 2) == [
            String(format: String(localized: "Matched: %@"), 9_500.formatted()),
            String(format: String(localized: "Updated: %@"), 9_500.formatted()),
            String(format: String(localized: "Inserted: %@"), 0.formatted()),
            String(format: String(localized: "Skipped: %@"), 500.formatted()),
            String(format: String(localized: "Failed: %@"), 2.formatted()),
        ])
    }

    @Test("Skip Existing counts a matched row as matched and skipped")
    func skipExistingCounts() {
        var tally = ImportRowTally(mode: .insertSkippingExisting)
        tally.existing = 3
        tally.inserted = 4
        #expect(tally.matched == 3)
        #expect(tally.skipped == 3)
    }

    @Test("Insert reports only what it inserted")
    func insertSummary() {
        var tally = ImportRowTally(mode: .insert)
        tally.inserted = 12
        #expect(tally.summaryLines(failed: 0) == [String(format: String(localized: "Inserted: %@"), 12.formatted())])
    }
}
