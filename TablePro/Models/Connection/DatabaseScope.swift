//
//  DatabaseScope.swift
//  TablePro
//

import Foundation

/// The full target of a database operation: which connection, which database, which schema.
/// A connection id alone cannot address an operation, because one connection reaches many
/// databases and a tab outlives the sidebar's current selection.
struct DatabaseScope: Hashable, Sendable {
    let connectionId: UUID
    let database: String
    let schema: String?

    init(connectionId: UUID, database: String, schema: String?) {
        self.connectionId = connectionId
        self.database = database
        self.schema = schema.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A connection can legitimately have no database selected, so an empty database means
    /// "the server", not "unbound". Server-scoped work runs on the session driver with no
    /// pin, which is what a connection in that state did before it had a scope at all.
    var isServerScoped: Bool { database.isEmpty }

    var qualifiedDescription: String {
        guard let schema else { return database }
        return "\(database).\(schema)"
    }
}
