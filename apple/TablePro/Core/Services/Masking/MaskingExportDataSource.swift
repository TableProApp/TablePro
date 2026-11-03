//
//  MaskingExportDataSource.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Stands between an export format and a data source that reads the database, so every row a format
/// receives, by stream or by its own query, has the connection's masking rules applied.
final class MaskingExportDataSource: PluginExportDataSource, @unchecked Sendable {
    private let base: any PluginExportDataSource
    private let policy: MaskingPolicy
    private let streamsTables: Bool

    /// `streamsTables` is false when the export table is a query result named after its output file, so a
    /// `table.column` rule matches by column name instead of by that name.
    static func wrapping(
        _ base: any PluginExportDataSource,
        policy: MaskingPolicy,
        streamsTables: Bool = true
    ) -> any PluginExportDataSource {
        policy.isEmpty ? base : MaskingExportDataSource(base: base, policy: policy, streamsTables: streamsTables)
    }

    init(base: any PluginExportDataSource, policy: MaskingPolicy, streamsTables: Bool = true) {
        self.base = base
        self.policy = policy
        self.streamsTables = streamsTables
    }

    var databaseTypeId: String { base.databaseTypeId }
    var tableDDLIncludesForeignKeys: Bool { base.tableDDLIncludesForeignKeys }
    var lexicalFeatures: SQLLexicalFeatures { base.lexicalFeatures }
    var supportsCascadeDrop: Bool { base.supportsCascadeDrop }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        Self.masking(base.streamRows(table: table, databaseName: databaseName), table: sourceTable(table), policy: policy)
    }

    func streamRows(for object: PluginExportTable) -> AsyncThrowingStream<PluginStreamElement, Error> {
        Self.masking(base.streamRows(for: object), table: sourceTable(object.name), policy: policy)
    }

    func streamExportRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginExportStreamElement, Error> {
        maskingDocuments(base.streamExportRows(table: table, databaseName: databaseName), table: sourceTable(table))
    }

    func streamExportRows(for object: PluginExportTable) -> AsyncThrowingStream<PluginExportStreamElement, Error> {
        maskingDocuments(base.streamExportRows(for: object), table: sourceTable(object.name))
    }

    private func maskingDocuments(
        _ stream: AsyncThrowingStream<PluginExportStreamElement, Error>,
        table: String?
    ) -> AsyncThrowingStream<PluginExportStreamElement, Error> {
        let policy = self.policy
        return AsyncThrowingStream { continuation in
            let task = Task {
                var header: PluginStreamHeader?
                do {
                    for try await element in stream {
                        switch element {
                        case .header(let value):
                            header = value
                            continuation.yield(element)
                        case .rows(let rows, let documents):
                            guard let header else {
                                throw PluginExportError.exportFailed("Rows arrived before their columns")
                            }
                            let masks = policy.columnMasks(table: table, columns: header.columns, typeNames: header.columnTypeNames)
                            if let documents, documents.count != rows.count {
                                throw PluginExportError.exportFailed("Documents do not match their rows")
                            }
                            let masked = documents?.enumerated().map { index, document in
                                ExportDocumentMasking.document(
                                    document, columns: header.columns, masks: masks,
                                    policy: policy, table: table, row: rows[index]
                                )
                            }
                            continuation.yield(.rows(masks.rows(rows), documents: masked))
                        @unknown default:
                            throw PluginExportError.encodingFailed
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func sourceTable(_ name: String) -> String? {
        streamsTables ? name : nil
    }

    func execute(query: String) async throws -> PluginQueryResult {
        try await base.execute(query: query).masked(by: policy)
    }

    static func masking(
        _ stream: AsyncThrowingStream<PluginStreamElement, Error>,
        table: String?,
        policy: MaskingPolicy
    ) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var masks: ColumnMasks?
                do {
                    for try await element in stream {
                        switch element {
                        case .header(let header):
                            masks = policy.columnMasks(table: table, columns: header.columns, typeNames: header.columnTypeNames)
                            continuation.yield(element)
                        case .rows(let rows):
                            // Without a header there are no column names to match, so no row goes out unmatched.
                            guard let masks else {
                                throw PluginExportError.exportFailed("Rows arrived before their columns")
                            }
                            continuation.yield(.rows(masks.rows(rows)))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        try await base.fetchTableDDL(table: table, databaseName: databaseName)
    }

    func quoteIdentifier(_ identifier: String) -> String {
        base.quoteIdentifier(identifier)
    }

    func escapeStringLiteral(_ value: String) -> String {
        base.escapeStringLiteral(value)
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? {
        try await base.fetchApproximateRowCount(table: table, databaseName: databaseName)
    }

    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] {
        try await base.fetchDependentSequences(table: table, databaseName: databaseName)
    }

    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] {
        try await base.fetchDependentTypes(table: table, databaseName: databaseName)
    }

    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        try await base.fetchColumns(table: table, databaseName: databaseName)
    }

    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] {
        try await base.fetchAllColumns(databaseName: databaseName)
    }

    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] {
        try await base.fetchForeignKeys(table: table, databaseName: databaseName)
    }

    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] {
        try await base.fetchAllForeignKeys(databaseName: databaseName)
    }

    func fetchIndexDDL(table: String, databaseName: String) async throws -> [String] {
        try await base.fetchIndexDDL(table: table, databaseName: databaseName)
    }

    func fetchCommentDDL(table: String, databaseName: String) async throws -> [String] {
        try await base.fetchCommentDDL(table: table, databaseName: databaseName)
    }

    func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
        try await base.fetchObjectDDL(object)
    }

    func scriptText(for ddl: String) -> String {
        base.scriptText(for: ddl)
    }

    func fetchGrantStatements(principal: String, host: String?) async throws -> [String] {
        try await base.fetchGrantStatements(principal: principal, host: host)
    }

    func dropStatement(for object: PluginExportTable) -> String? {
        base.dropStatement(for: object)
    }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        try await base.openSessionScope(for: purpose)
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        try await base.closeSessionScope(scope)
    }

    func fetchCreationScope(_ object: PluginExportTable) async throws -> PluginStatementScope? {
        try await base.fetchCreationScope(object)
    }

    func fetchIndexes(table: String, databaseName: String) async throws -> [PluginIndexInfo] {
        try await base.fetchIndexes(table: table, databaseName: databaseName)
    }

    func fetchObjectComment(_ object: PluginExportTable) async throws -> String? {
        try await base.fetchObjectComment(object)
    }
}

/// Document fields can outlive the sampled columns, so every stored field takes the policy too.
enum ExportDocumentMasking {
    static func document(
        _ document: PluginExportDocument,
        columns: [String],
        masks: ColumnMasks,
        policy: MaskingPolicy = .none,
        table: String? = nil,
        excluding: Set<String> = [],
        row: [PluginCellValue]? = nil
    ) -> PluginExportDocument {
        PluginExportDocument(fields: document.fields.map { field in
            guard !excluding.contains(field.name) else { return field }
            let index = columns.firstIndex(of: field.name)
            let style = index.flatMap { masks.styles[$0] }
                ?? policy.style(table: table, column: field.name, typeName: field.typeName)
            guard let style else { return field }
            let cell: PluginCellValue
            if let index, masks.styles[index] != nil, let row, row.indices.contains(index) {
                cell = row[index]
            } else {
                cell = field.cellValue
            }
            return replacing(field, with: MaskedValue.mask(cell, style: style))
        })
    }

    static func replacing(_ field: PluginExportField, with value: PluginCellValue) -> PluginExportField {
        let json: String
        switch value {
        case .null:
            json = "null"
        case .text(let text):
            json = PluginExportDocument.jsonString(text)
        case .bytes:
            // Every byte mask is text or null. A future mask must not pass original bytes through.
            json = PluginExportDocument.jsonString(MaskedValue.bullets)
        }
        return PluginExportField(name: field.name, canonicalJSON: json, typeName: "VARCHAR", cellValue: value)
    }
}
