//
//  ResultOrigin.swift
//  TablePro
//

import Foundation

/// Where one result set's rows came from, captured when its statement ran.
///
/// A query tab can hold several results at once: pinning keeps an older one and a multi-statement
/// run makes one per statement. `QueryTab.tableContext` only ever describes the newest execution,
/// and every edit is generated from that context, so without this a result the user clicked back
/// to would be written against whichever table ran last. The origin travels with the rows, and
/// `switchActiveResultSet` restores it.
struct ResultOrigin: Equatable {
    var tableName: String?
    var schemaName: String?
    var databaseName: String
    var primaryKeyColumns: [String]
    var isEditable: Bool
    var isView: Bool

    /// Whether anything has actually looked up this table's key columns. An empty
    /// `primaryKeyColumns` means two different things: a table that genuinely has no key, which
    /// the generator handles with a whole-row `WHERE`, and a table nobody has asked yet. Only the
    /// first is safe to write to, so the two cannot share a representation.
    var keysResolved: Bool

    init(
        tableName: String? = nil,
        schemaName: String? = nil,
        databaseName: String = "",
        primaryKeyColumns: [String] = [],
        isEditable: Bool = false,
        isView: Bool = false,
        keysResolved: Bool = false
    ) {
        self.tableName = tableName
        self.schemaName = schemaName
        self.databaseName = databaseName
        self.primaryKeyColumns = primaryKeyColumns
        self.isEditable = isEditable
        self.isView = isView
        self.keysResolved = keysResolved
    }
}

/// Why a result's rows cannot be edited. Refusing without saying why reads as a broken grid, so
/// every case carries the sentence shown to the user.
enum ResultEditRefusal: Equatable {
    case unknownTable
    case view
    case databaseMoved
    case keysUnresolved

    var message: String {
        switch self {
        case .unknownTable:
            return String(localized: "These rows cannot be edited because TablePro cannot tell which table they came from.")
        case .view:
            return String(localized: "These rows come from a view, which cannot be edited.")
        case .databaseMoved:
            return String(localized: "These rows came from another database than the one this tab is now using.")
        case .keysUnresolved:
            return String(localized: "TablePro has not looked up this table's key columns, so it cannot tell which row an edit would change.")
        }
    }
}

/// The single decision about whether a result's rows may be written back.
///
/// It is pure so the rule can be tested without a coordinator, and it is fail-closed: a result
/// with no captured origin refuses rather than borrowing the tab's current table.
enum ResultEditability {
    static func refusal(for origin: ResultOrigin?, currentDatabaseName: String) -> ResultEditRefusal? {
        guard let origin else { return .unknownTable }
        if origin.isView { return .view }
        guard origin.isEditable, let tableName = origin.tableName, !tableName.isEmpty else {
            return .unknownTable
        }
        guard origin.keysResolved else { return .keysUnresolved }
        guard origin.databaseName.isEmpty || currentDatabaseName.isEmpty
            || origin.databaseName == currentDatabaseName
        else {
            return .databaseMoved
        }
        return nil
    }
}
