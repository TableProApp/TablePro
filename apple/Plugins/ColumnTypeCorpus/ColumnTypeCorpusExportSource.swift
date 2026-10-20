//
//  ColumnTypeCorpusExportSource.swift
//  ColumnTypeCorpus
//

import Foundation
import TableProPluginKit

// What the host's ExportDataSourceAdapter hands an export plugin for one table of the connected database.
final class ColumnTypeCorpusExportSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId: String
    let lexicalFeatures: SQLLexicalFeatures
    let supportsCascadeDrop: Bool
    private let driver: any PluginDatabaseDriver

    init(
        driver: any PluginDatabaseDriver,
        databaseTypeId: String,
        lexicalFeatures: SQLLexicalFeatures,
        supportsCascadeDrop: Bool
    ) {
        self.driver = driver
        self.databaseTypeId = databaseTypeId
        self.lexicalFeatures = lexicalFeatures
        self.supportsCascadeDrop = supportsCascadeDrop
    }

    static func readQuery(table: String, driver: any PluginDatabaseDriver) -> (sql: String, context: PluginStatementContext) {
        var context = PluginStatementContext()
        context.readOnly = true
        if let custom = driver.defaultExportQuery(table: table, schema: nil) {
            return (custom, context)
        }
        return ("SELECT * FROM \(driver.quoteIdentifier(table))", context)
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let read = Self.readQuery(table: table, driver: driver)
        return driver.streamRows(query: read.sql, context: read.context)
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        try await driver.fetchTableDDL(table: table, schema: nil)
    }

    func execute(query: String) async throws -> PluginQueryResult {
        try await driver.execute(query: query)
    }

    func quoteIdentifier(_ identifier: String) -> String {
        driver.quoteIdentifier(identifier)
    }

    func escapeStringLiteral(_ value: String) -> String {
        driver.escapeStringLiteral(value)
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? {
        try await driver.fetchApproximateRowCount(table: table, schema: nil)
    }

    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        try await driver.fetchColumns(table: table, schema: nil)
    }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        try await driver.openSessionScope(for: purpose)
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        try await driver.closeSessionScope(scope)
    }
}
