//
//  OperationCompletion.swift
//  TablePro
//

import Foundation

// Only work the user started: a health ping, schema load or background row count never becomes one.
internal enum TrackedOperationKind: String, CaseIterable, Sendable {
    case query
    case queryBatch
    case rowSave
    case schemaChange
    case dataImport
    case dataExport
    case objectCopy
    case backup
    case restore
    case compareRun
    case compareApply
    case fetchAll
    case mcpQuery
    case scriptQuery
}

// What a completion is attributed to and what a click focuses; `connection` is for work with no tab, like MCP queries.
internal enum OperationOwner: Hashable, Sendable {
    case tab(windowId: UUID?, tabId: UUID)
    case connection(UUID)
    case compareWindow(UUID)

    internal var tabId: UUID? {
        guard case .tab(_, let tabId) = self else { return nil }
        return tabId
    }

    internal var windowId: UUID? {
        guard case .tab(let windowId, _) = self else { return nil }
        return windowId
    }
}

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

// Cancelled is its own outcome: folding it into either would notify about work the user stopped.
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
