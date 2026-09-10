//
//  JSONRowNode.swift
//  TablePro
//
//  Immutable tree a single result row is rendered from in the JSON inspector.
//

import Foundation

struct JSONNodePath: Hashable, Sendable {
    let components: [String]

    static let root = JSONNodePath(components: [])

    func appending(_ component: String) -> JSONNodePath {
        JSONNodePath(components: components + [component])
    }

    var rawValue: String {
        components.joined(separator: "\u{001F}")
    }

    var depth: Int { components.count }
}

enum JSONNodeKey: Equatable, Sendable {
    case root
    case name(String)
    case index(Int)

    var text: String? {
        switch self {
        case .root: nil
        case .name(let name): name
        case .index: nil
        }
    }
}

enum JSONScalar: Equatable, Sendable {
    case string(String)
    case number(String)
    case bool(Bool)
    case null
    case binary(Data)

    var searchableText: String {
        switch self {
        case .string(let text): text
        case .number(let text): text
        case .bool(let flag): flag ? "true" : "false"
        case .null: "null"
        case .binary: ""
        }
    }
}

/// The parts of a `ForeignKeyInfo` an expansion needs, without its per-instance identity.
///
/// `ForeignKeyInfo` carries a fresh `UUID` and takes it into `==`, so two descriptions of the same
/// constraint never compare equal. A node tree that has to diff cleanly cannot hold one.
struct JSONForeignKeyRef: Hashable, Sendable {
    let column: String
    let referencedTable: String
    let referencedSchema: String?
    let referencedColumn: String

    init(column: String, referencedTable: String, referencedSchema: String?, referencedColumn: String) {
        self.column = column
        self.referencedTable = referencedTable
        self.referencedSchema = referencedSchema
        self.referencedColumn = referencedColumn
    }

    init(_ info: ForeignKeyInfo) {
        self.init(
            column: info.column,
            referencedTable: info.referencedTable,
            referencedSchema: info.referencedSchema,
            referencedColumn: info.referencedColumn
        )
    }

    var qualifiedTable: String {
        guard let referencedSchema, !referencedSchema.isEmpty else { return referencedTable }
        return "\(referencedSchema).\(referencedTable)"
    }
}

enum JSONNodeValue: Equatable, Sendable {
    case scalar(JSONScalar)
    case object([JSONRowNode])
    case array([JSONRowNode])
    /// A scalar the referenced row can be fetched for. Children arrive from the fetch, not from here.
    case foreignKey(JSONForeignKeyRef, JSONScalar)
}

struct JSONRowNode: Identifiable, Equatable, Sendable {
    let path: JSONNodePath
    let key: JSONNodeKey
    let value: JSONNodeValue

    var id: String { path.rawValue }

    var children: [JSONRowNode] {
        switch value {
        case .object(let nodes), .array(let nodes): nodes
        case .scalar, .foreignKey: []
        }
    }

    var isContainer: Bool {
        switch value {
        case .object, .array: true
        case .scalar, .foreignKey: false
        }
    }

    var foreignKey: JSONForeignKeyRef? {
        guard case .foreignKey(let ref, _) = value else { return nil }
        return ref
    }

    var scalar: JSONScalar? {
        switch value {
        case .scalar(let scalar): scalar
        case .foreignKey(_, let scalar): scalar
        case .object, .array: nil
        }
    }
}
