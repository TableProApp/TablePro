//
//  DatabaseTreeTableDetailRef.swift
//  TablePro
//

import Foundation

/// One detail of a table as the sidebar lists it. A foreign key is one row per constraint, so a key
/// over two columns reads as one key rather than two.
enum TableDetailItem: Hashable, Sendable {
    case column(ColumnInfo)
    case index(IndexInfo)
    case foreignKey(EditableForeignKeyDefinition)
    case check(CheckConstraintInfo)

    var name: String {
        switch self {
        case .column(let column): column.name
        case .index(let index): index.name
        case .foreignKey(let key): key.name
        case .check(let check): check.name
        }
    }
}

/// One detail group under one table row.
struct DatabaseTreeTableDetailGroupRef: Hashable, Sendable {
    let table: DatabaseTreeTableRef
    let kind: TableDetailGroupKind

    var expansionKey: DatabaseTableDetailGroupKey {
        DatabaseTableDetailGroupKey(table: DatabaseTableKey(table), group: kind)
    }
}

/// One column, index, foreign key or check, with the table it belongs to, which is what its menu
/// and its double-click open.
struct DatabaseTreeTableDetailRef: Hashable, Sendable {
    let table: DatabaseTreeTableRef
    let item: TableDetailItem
}
