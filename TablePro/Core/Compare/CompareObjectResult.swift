//
//  CompareObjectResult.swift
//  TablePro
//
//  One row of a comparison, whatever kind of object it is.
//
//  A table is compared as parsed metadata and yields a `SchemaChange` list. A
//  view, procedure, function or trigger has no such structure: its definition is
//  a body of SQL, so it is compared as normalised text and the only honest
//  answers are create, replace and drop. Both arrive here as one type, so the
//  results list, the selection model and the script builder do not each need to
//  know which engine produced a row.
//

import Foundation

internal struct CompareObjectIdentity: Hashable, Sendable {
    internal let kind: CompareObjectKind
    internal let schema: String?
    internal let name: String

    /// Distinguishes two routines that share a name, which PostgreSQL and Oracle both allow.
    /// Nil for everything that cannot be overloaded.
    internal let signature: String?

    internal init(kind: CompareObjectKind, schema: String?, name: String, signature: String? = nil) {
        self.kind = kind
        self.schema = schema
        self.name = name
        self.signature = signature
    }

    internal var qualifiedName: String {
        guard let schema, !schema.isEmpty else { return name }
        return "\(schema).\(name)"
    }

    internal var displayName: String {
        guard let signature, !signature.isEmpty else { return qualifiedName }
        return "\(qualifiedName)\(signature)"
    }

    internal var id: String {
        "\(kind.rawValue)|\(schema ?? "")|\(name)|\(signature ?? "")"
    }
}

internal struct CompareObjectResult: Identifiable, Hashable, Sendable {
    internal let identity: CompareObjectIdentity
    internal let status: TableDiffStatus
    internal let changes: [SchemaChange]
    internal let sourceDefinition: [String]
    internal let targetDefinition: [String]
    internal let notes: [String]
    internal let comparisonError: String?

    internal init(
        identity: CompareObjectIdentity,
        status: TableDiffStatus,
        changes: [SchemaChange] = [],
        sourceDefinition: [String] = [],
        targetDefinition: [String] = [],
        notes: [String] = [],
        comparisonError: String? = nil
    ) {
        self.identity = identity
        self.status = status
        self.changes = changes
        self.sourceDefinition = sourceDefinition
        self.targetDefinition = targetDefinition
        self.notes = notes
        self.comparisonError = comparisonError
    }

    internal var id: String { identity.id }

    internal var isComparable: Bool { comparisonError == nil }

    internal var suggestedAction: TableSyncAction {
        guard comparisonError == nil else { return .skip }
        switch status {
        case .onlyInSource: return .create
        case .onlyInTarget: return .drop
        case .differs: return .alter
        case .identical: return .skip
        }
    }

    internal var availableActions: [TableSyncAction] {
        guard comparisonError == nil else { return [.skip] }
        switch status {
        case .onlyInSource: return [.skip, .create]
        case .onlyInTarget: return [.skip, .drop]
        case .differs: return [.skip, .alter]
        case .identical: return [.skip]
        }
    }
}

internal extension CompareObjectResult {
    /// Table results come from `StructureDiffEngine`, which stays table-shaped and keeps its tests.
    static func from(
        _ result: TableDiffResult,
        sourceDefinition: [String] = [],
        targetDefinition: [String] = []
    ) -> CompareObjectResult {
        CompareObjectResult(
            identity: CompareObjectIdentity(kind: .table, schema: result.schema, name: result.tableName),
            status: result.status,
            changes: result.changes,
            sourceDefinition: sourceDefinition,
            targetDefinition: targetDefinition,
            notes: result.notes,
            comparisonError: result.comparisonError
        )
    }
}

internal struct CompareReport: Sendable {
    internal let results: [CompareObjectResult]

    internal init(results: [CompareObjectResult]) {
        self.results = results.sorted { lhs, rhs in
            guard lhs.identity.kind == rhs.identity.kind else {
                return Self.kindRank(lhs.identity.kind) < Self.kindRank(rhs.identity.kind)
            }
            return lhs.identity.displayName.localizedStandardCompare(rhs.identity.displayName) == .orderedAscending
        }
    }

    internal var comparable: [CompareObjectResult] {
        results.filter { $0.isComparable }
    }

    internal var uncomparable: [CompareObjectResult] {
        results.filter { !$0.isComparable }
    }

    internal func count(of status: TableDiffStatus) -> Int {
        comparable.filter { $0.status == status }.count
    }

    internal var differenceCount: Int {
        comparable.filter { $0.status != .identical }.count
    }

    internal var presentKinds: [CompareObjectKind] {
        var seen: [CompareObjectKind] = []
        for result in results where !seen.contains(result.identity.kind) {
            seen.append(result.identity.kind)
        }
        return seen
    }

    /// Dependency order, so a script that both drops and creates does not trip over itself.
    private static func kindRank(_ kind: CompareObjectKind) -> Int {
        switch kind {
        case .table: return 0
        case .sequence: return 1
        case .view: return 2
        case .materializedView: return 3
        case .function: return 4
        case .procedure: return 5
        case .trigger: return 6
        }
    }
}
