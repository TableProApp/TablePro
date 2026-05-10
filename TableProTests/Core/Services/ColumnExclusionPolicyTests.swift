//
//  ColumnExclusionPolicyTests.swift
//  TableProTests
//
//  Tests for ColumnExclusionPolicy selective column exclusion logic.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("ColumnExclusionPolicy")
struct ColumnExclusionPolicyTests {
    private func quoteMySQL(_ name: String) -> String {
        "`\(name)`"
    }

    private func quoteStandard(_ name: String) -> String {
        "\"\(name)\""
    }

    @Test("BLOB column NOT excluded (no lazy-load fetch path for editing/export)")
    func blobColumnNotExcluded() {
        let columns = ["id", "name", "photo"]
        let types: [ColumnType] = [
            .integer(rawType: "INT"),
            .text(rawType: "VARCHAR"),
            .blob(rawType: "BLOB")
        ]
        let exclusions = ColumnExclusionPolicy.exclusions(
            columns: columns, columnTypes: types,
            databaseType: .mysql, quoteIdentifier: quoteMySQL
        )
        #expect(exclusions.isEmpty)
    }

    @Test("LONGTEXT column excluded with SUBSTRING expression")
    func longTextColumnExcluded() {
        let columns = ["id", "content"]
        let types: [ColumnType] = [
            .integer(rawType: "INT"),
            .text(rawType: "LONGTEXT")
        ]
        let exclusions = ColumnExclusionPolicy.exclusions(
            columns: columns, columnTypes: types,
            databaseType: .mysql, quoteIdentifier: quoteMySQL
        )
        #expect(exclusions.count == 1)
        #expect(exclusions[0].columnName == "content")
        #expect(exclusions[0].placeholderExpression == "SUBSTRING(`content`, 1, 256)")
    }

    @Test("VARCHAR and INTEGER columns NOT excluded")
    func normalColumnsNotExcluded() {
        let columns = ["id", "name", "age"]
        let types: [ColumnType] = [
            .integer(rawType: "INT"),
            .text(rawType: "VARCHAR"),
            .integer(rawType: "BIGINT")
        ]
        let exclusions = ColumnExclusionPolicy.exclusions(
            columns: columns, columnTypes: types,
            databaseType: .mysql, quoteIdentifier: quoteMySQL
        )
        #expect(exclusions.isEmpty)
    }

    @Test("DATE and TIMESTAMP columns NOT excluded")
    func dateColumnsNotExcluded() {
        let columns = ["created_at", "updated_at"]
        let types: [ColumnType] = [
            .date(rawType: "DATE"),
            .timestamp(rawType: "TIMESTAMP")
        ]
        let exclusions = ColumnExclusionPolicy.exclusions(
            columns: columns, columnTypes: types,
            databaseType: .postgresql, quoteIdentifier: quoteStandard
        )
        #expect(exclusions.isEmpty)
    }

    @Test("Empty columns produces no exclusions")
    func emptyColumnsNoExclusions() {
        let exclusions = ColumnExclusionPolicy.exclusions(
            columns: [], columnTypes: [],
            databaseType: .mysql, quoteIdentifier: quoteMySQL
        )
        #expect(exclusions.isEmpty)
    }

    @Test("MSSQL BLOB column NOT excluded")
    func mssqlBlobNotExcluded() {
        let columns = ["data"]
        let types: [ColumnType] = [.blob(rawType: "VARBINARY")]
        let exclusions = ColumnExclusionPolicy.exclusions(
            columns: columns, columnTypes: types,
            databaseType: .mssql, quoteIdentifier: quoteStandard
        )
        #expect(exclusions.isEmpty)
    }

    @Test("Plain TEXT column NOT excluded (only MEDIUMTEXT/LONGTEXT/CLOB)")
    func plainTextNotExcluded() {
        let columns = ["body"]
        let types: [ColumnType] = [.text(rawType: "TEXT")]
        let exclusions = ColumnExclusionPolicy.exclusions(
            columns: columns, columnTypes: types,
            databaseType: .sqlite, quoteIdentifier: quoteStandard
        )
        #expect(exclusions.isEmpty)
    }

    @Test("SQLite uses SUBSTR for CLOB columns")
    func sqliteUsesSubstr() {
        let columns = ["body"]
        let types: [ColumnType] = [.text(rawType: "CLOB")]
        let exclusions = ColumnExclusionPolicy.exclusions(
            columns: columns, columnTypes: types,
            databaseType: .sqlite, quoteIdentifier: quoteStandard
        )
        #expect(exclusions.count == 1)
        #expect(exclusions[0].placeholderExpression == "SUBSTR(\"body\", 1, 256)")
    }

    @Test("Only MEDIUMTEXT excluded in mixed column set, BLOB kept")
    func mixedExclusions() {
        let columns = ["id", "photo", "content", "name"]
        let types: [ColumnType] = [
            .integer(rawType: "INT"),
            .blob(rawType: "BLOB"),
            .text(rawType: "MEDIUMTEXT"),
            .text(rawType: "VARCHAR")
        ]
        let exclusions = ColumnExclusionPolicy.exclusions(
            columns: columns, columnTypes: types,
            databaseType: .postgresql, quoteIdentifier: quoteStandard
        )
        #expect(exclusions.count == 1)
        #expect(exclusions[0].columnName == "content")
        #expect(exclusions[0].placeholderExpression == "SUBSTRING(\"content\", 1, 256)")
    }

    @Test("Mismatched column/type counts handled safely")
    func mismatchedCounts() {
        let columns = ["id", "name", "photo"]
        let types: [ColumnType] = [
            .integer(rawType: "INT"),
            .text(rawType: "VARCHAR")
        ]
        let exclusions = ColumnExclusionPolicy.exclusions(
            columns: columns, columnTypes: types,
            databaseType: .mysql, quoteIdentifier: quoteMySQL
        )
        #expect(exclusions.isEmpty)
    }
}
