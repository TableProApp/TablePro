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
    let database: String
    let schema: String?
    let isSystem: Bool

    var id: String {
        switch kind {
        case .database: "database\u{1}\(database)"
        case .schema: "schema\u{1}\(database)\u{1}\(schema ?? "")"
        }
    }

    var name: String {
        switch kind {
        case .database: database
        case .schema: schema ?? database
        }
    }

    static func database(_ name: String, isSystem: Bool = false) -> DatabaseContainerRef {
        DatabaseContainerRef(kind: .database, database: name, schema: nil, isSystem: isSystem)
    }

    static func schema(database: String, schema: String, isSystem: Bool = false) -> DatabaseContainerRef {
        DatabaseContainerRef(kind: .schema, database: database, schema: schema, isSystem: isSystem)
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
