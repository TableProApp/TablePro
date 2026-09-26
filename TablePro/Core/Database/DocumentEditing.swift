//
//  DocumentEditing.swift
//  TablePro
//
//  Reads and writes a whole document, for engines that store documents.
//

import Foundation
import TableProPluginKit

/// What a document sheet was opened for.
///
/// The collection and its database travel with the request, because the object browser may point
/// somewhere else by the time the user saves, and the document belongs to the collection the sheet
/// was opened on. An edit carries the row's locator, taken when the command was chosen, so a reload
/// that lands before the sheet opens cannot point it at another row's document.
struct DocumentEditorRequest: Identifiable, Equatable {
    enum Kind: Equatable {
        case insert
        case edit(locator: String)
    }

    let id: UUID
    let table: String
    let scope: DatabaseScope
    let kind: Kind

    init(id: UUID = UUID(), table: String, scope: DatabaseScope, kind: Kind = .insert) {
        self.id = id
        self.table = table
        self.scope = scope
        self.kind = kind
    }
}

enum DocumentEditingError: LocalizedError, Equatable {
    case notConnected
    case denied(String)
    case documentNotLoaded

    var errorDescription: String? {
        switch self {
        case .notConnected:
            String(localized: "Not connected to database")
        case .denied(let reason):
            reason
        case .documentNotLoaded:
            String(localized: "The document has not loaded, so there is nothing to save it over.")
        }
    }
}

@MainActor
enum DocumentEditing {
    /// The stored document an edit starts from, or nil when it no longer exists. An insert starts
    /// from nothing.
    static func load(_ request: DocumentEditorRequest) async throws -> String? {
        guard case .edit(let locator) = request.kind else { return nil }
        return try await DatabaseManager.shared.fetchDocument(
            locator: locator,
            table: request.table,
            scope: request.scope
        )
    }

    /// Writes `text` as a new document, or over the stored one `original` was read as. Returns
    /// without writing when an edit changes nothing.
    static func save(
        _ text: String,
        original: String?,
        for request: DocumentEditorRequest,
        databaseType: DatabaseType,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws {
        let write = PluginDocumentWrite(
            table: request.table,
            schema: request.scope.schema,
            operation: try operation(for: request.kind, text: text, original: original)
        )
        guard let driver = DatabaseManager.shared.driver(for: request.scope.connectionId) else {
            throw DocumentEditingError.notConnected
        }
        guard let statement = try await statement(for: write, on: driver) else { return }

        try await DatabaseManager.shared.executeDocumentWrite(
            write,
            statement: statement,
            databaseType: databaseType,
            scope: request.scope,
            operationDescription: operationDescription(for: request.kind),
            gate: gate
        )
    }

    /// An edit is never turned into an insert: without the text it was read as, there is no
    /// document to replace, and writing a new one would duplicate it.
    static func operation(
        for kind: DocumentEditorRequest.Kind,
        text: String,
        original: String?
    ) throws -> PluginDocumentWrite.Operation {
        switch kind {
        case .insert:
            return .insert(document: text)
        case .edit:
            guard let original else { throw DocumentEditingError.documentNotLoaded }
            return .replace(original: original, edited: text)
        }
    }

    static func operationDescription(for kind: DocumentEditorRequest.Kind) -> String {
        switch kind {
        case .insert:
            String(localized: "Insert Document")
        case .edit:
            String(localized: "Edit Document")
        }
    }

    /// Off the main actor, because the driver reads and compares the whole document to build it.
    @concurrent
    nonisolated private static func statement(
        for write: PluginDocumentWrite,
        on driver: DatabaseDriver
    ) async throws -> String? {
        try driver.documentWriteStatement(write)
    }
}
