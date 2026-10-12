//
//  DatabaseTreeRenameSession.swift
//  TablePro
//

import Foundation

/// What the object tree is renaming.
///
/// Identity only, no cell and no field. The outline holds its reloads while a rename is open, but a
/// collapse or a scroll can still take the row's cell away, so the cell is resolved from the node id
/// when the edit ends rather than kept.
internal struct DatabaseTreeRenameSession: Equatable {
    internal enum Target: Equatable {
        case table(DatabaseTreeTableRef)
        case container(DatabaseContainerRef)
        /// A folder's name lives only in TablePro, so committing it never reaches the database.
        case folder(TableFolder)
    }

    internal let target: Target
    internal let nodeId: String
    internal let originalName: String
    internal var pendingName: String?
}

/// Whether a typed name is worth sending to the server.
///
/// The three answers are separate because two of them are not failures. An unchanged name is the
/// user finishing where they started, and an empty field is a rename they abandoned; neither is
/// worth an alert, and neither should reach a driver that would answer with a syntax error.
internal enum RenameNameDecision: Equatable {
    case commit(String)
    case unchanged
    case discard

    internal static func decide(typed: String, original: String) -> RenameNameDecision {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .discard }
        guard trimmed != original else { return .unchanged }
        return .commit(trimmed)
    }
}
