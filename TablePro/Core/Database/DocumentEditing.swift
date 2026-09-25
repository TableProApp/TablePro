//
//  DocumentEditing.swift
//  TablePro
//
//  Writes a whole document, for engines that store documents.
//

import Foundation
import TableProPluginKit

/// What an Insert Document sheet was opened for.
///
/// The collection and its database travel with the request, because the object browser may point
/// somewhere else by the time the user presses Insert, and the document belongs to the collection the
/// sheet was opened on.
struct DocumentEditorRequest: Identifiable, Equatable {
    let id: UUID
    let table: String
    let scope: DatabaseScope

    init(id: UUID = UUID(), table: String, scope: DatabaseScope) {
        self.id = id
        self.table = table
        self.scope = scope
    }
}

enum DocumentEditingError: LocalizedError, Equatable {
    case notConnected
    case denied(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            String(localized: "Not connected to database")
        case .denied(let reason):
            reason
        }
    }
}

@MainActor
enum DocumentEditing {
    static func insert(
        _ text: String,
        for request: DocumentEditorRequest,
        databaseType: DatabaseType,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws {
        let write = PluginDocumentWrite(
            table: request.table,
            schema: request.scope.schema,
            operation: .insert(document: text)
        )
        guard let driver = DatabaseManager.shared.driver(for: request.scope.connectionId) else {
            throw DocumentEditingError.notConnected
        }
        guard let statement = try driver.documentWriteStatement(write) else { return }

        try await DatabaseManager.shared.executeDocumentWrite(
            write,
            statement: statement,
            databaseType: databaseType,
            scope: request.scope,
            operationDescription: String(localized: "Insert Document"),
            gate: gate
        )
    }
}
