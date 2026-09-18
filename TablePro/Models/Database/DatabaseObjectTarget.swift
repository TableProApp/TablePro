//
//  DatabaseObjectTarget.swift
//  TablePro
//

import Foundation

/// One table-like object a command acts on, with the scope its statement runs in.
///
/// The scope comes from the object's own database and schema, never from where the sidebar or the
/// selected tab happens to point, so a command raised on a view in another schema cannot act on a
/// same-named view in the browsed one.
struct DatabaseObjectTarget: Equatable, Sendable {
    let name: String
    let type: TableInfo.TableType
    let schema: String?
    let scope: DatabaseScope

    /// How the object is named to the user: its schema and its name, as the sidebar shows them.
    var qualifiedName: String {
        guard let schema, !schema.isEmpty else { return name }
        return "\(schema).\(name)"
    }

    func change(_ kind: DatabaseObjectChange.Kind) -> DatabaseObjectChange {
        DatabaseObjectChange(connectionId: scope.connectionId, scope: scope, name: name, kind: kind)
    }
}
