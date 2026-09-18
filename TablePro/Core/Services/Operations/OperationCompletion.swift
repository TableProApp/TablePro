//
//  OperationCompletion.swift
//  TablePro
//

import Foundation

/// A long-running thing the user started. Work the app starts on its own is deliberately absent:
/// a health ping, a schema load, an autocomplete prefetch and a background row count never become
/// an operation, because the user never asked for them and cannot be waiting on one.
internal enum TrackedOperationKind: String, CaseIterable, Sendable {
    case query
    case queryBatch
    case rowSave
    case schemaChange
    case dataImport
    case dataExport
    case objectCopy
    case backup
    case fetchAll
    case mcpQuery
    case scriptQuery
}

/// What a completion can be attributed to, which is also what a click can focus. A tab-owned
/// operation carries the window so the click reaches the right one when a connection is open in
/// several. `connection` is for work with no tab at all, which is every MCP-driven query.
internal enum OperationOwner: Hashable, Sendable {
    case tab(windowId: UUID?, tabId: UUID)
    case connection(UUID)

    internal var tabId: UUID? {
        guard case .tab(_, let tabId) = self else { return nil }
        return tabId
    }

    internal var windowId: UUID? {
        guard case .tab(let windowId, _) = self else { return nil }
        return windowId
    }
}

/// The numbers a completion can quote. Every field is optional because no operation fills them
/// all: a SELECT has rows returned, an UPDATE has rows affected, a batch has a statement count,
/// an export has a file.
internal struct OperationSummary: Equatable, Sendable {
    internal var rowsReturned: Int?
    internal var rowsAffected: Int?
    internal var statementCount: Int?
    internal var fileURL: URL?

    internal init(
        rowsReturned: Int? = nil,
        rowsAffected: Int? = nil,
        statementCount: Int? = nil,
        fileURL: URL? = nil
    ) {
        self.rowsReturned = rowsReturned
        self.rowsAffected = rowsAffected
        self.statementCount = statementCount
        self.fileURL = fileURL
    }
}

/// Three outcomes, never two. Cancellation is not a failure and not a success, and collapsing it
/// into either is what produces a notification for work the user themselves stopped.
internal enum OperationOutcome: Equatable, Sendable {
    case succeeded(OperationSummary)
    case failed(reason: String)
    case cancelled
}

internal struct OperationCompletion: Equatable, Sendable {
    internal let kind: TrackedOperationKind
    internal let owner: OperationOwner
    internal let connectionId: UUID
    internal let connectionName: String
    internal let databaseName: String?
    internal let elapsed: Duration
    internal let outcome: OperationOutcome

    internal init(
        kind: TrackedOperationKind,
        owner: OperationOwner,
        connectionId: UUID,
        connectionName: String,
        databaseName: String? = nil,
        elapsed: Duration,
        outcome: OperationOutcome
    ) {
        self.kind = kind
        self.owner = owner
        self.connectionId = connectionId
        self.connectionName = connectionName
        self.databaseName = databaseName
        self.elapsed = elapsed
        self.outcome = outcome
    }
}
