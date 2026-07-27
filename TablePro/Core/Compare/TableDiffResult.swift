//
//  TableDiffResult.swift
//  TablePro
//
//  Outcome of comparing one table between a source and a target connection.
//

import Foundation

internal enum TableDiffStatus: String, Codable, Hashable, Sendable {
    case onlyInSource
    case onlyInTarget
    case differs
    case identical
}

internal enum TableSyncAction: String, Codable, Hashable, Sendable, CaseIterable {
    case create
    case alter
    case drop
    case skip
}

internal struct TableDiffResult: Identifiable, Hashable {
    internal let tableName: String
    internal let schema: String?
    internal let status: TableDiffStatus
    internal let changes: [SchemaChange]
    internal let notes: [String]
    internal let comparisonError: String?

    internal var id: String {
        guard let schema, !schema.isEmpty else { return tableName }
        return "\(schema).\(tableName)"
    }

    internal init(
        tableName: String,
        schema: String?,
        status: TableDiffStatus,
        changes: [SchemaChange] = [],
        notes: [String] = [],
        comparisonError: String? = nil
    ) {
        self.tableName = tableName
        self.schema = schema
        self.status = status
        self.changes = changes
        self.notes = notes
        self.comparisonError = comparisonError
    }

    internal var isComparable: Bool {
        comparisonError == nil
    }

    internal var suggestedAction: TableSyncAction {
        guard comparisonError == nil else { return .skip }
        switch status {
        case .onlyInSource: return .create
        case .onlyInTarget: return .drop
        case .differs: return .alter
        case .identical: return .skip
        }
    }
}

internal struct StructureDiffReport {
    internal let results: [TableDiffResult]

    internal init(results: [TableDiffResult]) {
        self.results = results
    }

    internal var comparable: [TableDiffResult] {
        results.filter { $0.isComparable }
    }

    internal var uncomparable: [TableDiffResult] {
        results.filter { !$0.isComparable }
    }

    internal func count(of status: TableDiffStatus) -> Int {
        comparable.filter { $0.status == status }.count
    }
}
