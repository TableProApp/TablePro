//
//  JSONForeignKeyExpansionPolicy.swift
//  TablePro
//
//  How far the JSON inspector follows a chain of foreign keys.
//

import Foundation

struct JSONForeignKeyVisit: Hashable, Sendable {
    let table: String
    let schema: String?
    let column: String
    let value: String?

    init(table: String, schema: String?, column: String, value: String?) {
        self.table = table
        self.schema = schema
        self.column = column
        self.value = value
    }

    init(ref: JSONForeignKeyRef, value: String?) {
        self.init(
            table: ref.referencedTable,
            schema: ref.referencedSchema,
            column: ref.referencedColumn,
            value: value
        )
    }
}

enum JSONForeignKeyExpansionDecision: Equatable, Sendable {
    case allowed
    case cycle
    case depthLimit
}

/// A row that references itself, directly or through another table, is ordinary schema design, so
/// the chain has to be checked rather than trusted: `employee.manager_id → employee` expands
/// forever otherwise. The depth cap covers the chains that do terminate but only after more
/// round trips than a reader wants.
enum JSONForeignKeyExpansionPolicy {
    static let maxChainDepth = 5

    /// How many levels "Always Expand Foreign Keys" fetches without being asked. One: the setting
    /// exists to save the first click, not to walk the schema on every selection change.
    static let autoExpandDepth = 1

    static func decide(
        chain: [JSONForeignKeyVisit],
        next: JSONForeignKeyVisit
    ) -> JSONForeignKeyExpansionDecision {
        if chain.contains(next) { return .cycle }
        guard chain.count < maxChainDepth else { return .depthLimit }
        return .allowed
    }
}
