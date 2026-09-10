//
//  DatabaseContainerRef.swift
//  TablePro
//

import Foundation

struct DatabaseContainerRef: Hashable, Identifiable {
    enum Kind: Hashable {
        case database
        case schema
    }

    let kind: Kind
    /// Nil when the connection browses no database, which is the normal state for an engine that
    /// has none. Kept optional so it compares equal to an equally optional active database; an
    /// empty string never matched nil and made every schema look like a different container.
    let database: String?
    let schema: String?
    let isSystem: Bool

    var id: String {
        switch kind {
        case .database: "database\u{1}\(database ?? "")"
        case .schema: "schema\u{1}\(database ?? "")\u{1}\(schema ?? "")"
        }
    }

    var name: String {
        switch kind {
        case .database: database ?? ""
        case .schema: schema ?? database ?? ""
        }
    }

    static func database(_ name: String, isSystem: Bool = false) -> DatabaseContainerRef {
        DatabaseContainerRef(kind: .database, database: name, schema: nil, isSystem: isSystem)
    }

    static func schema(database: String?, schema: String, isSystem: Bool = false) -> DatabaseContainerRef {
        DatabaseContainerRef(kind: .schema, database: database, schema: schema, isSystem: isSystem)
    }

    /// Whether selecting this container implies selecting `other`. A database covers itself and
    /// every schema inside it, which is what makes "export this database" select all of its schemas
    /// on an engine that lists schemas. A schema covers only itself.
    func covers(_ other: DatabaseContainerRef) -> Bool {
        guard database == other.database else { return false }
        switch kind {
        case .database: return true
        case .schema: return other.kind == .schema && schema == other.schema
        }
    }

    static func == (lhs: DatabaseContainerRef, rhs: DatabaseContainerRef) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension [DatabaseContainerRef] {
    var sortedByName: [DatabaseContainerRef] {
        sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func matching(kind: DatabaseContainerRef.Kind) -> [DatabaseContainerRef] {
        filter { $0.kind == kind }
    }
}
