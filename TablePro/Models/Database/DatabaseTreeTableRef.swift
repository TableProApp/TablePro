//
//  DatabaseTreeTableRef.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// One table, named by everything it takes to reach it.
///
/// `database` is nil when the connection browses no database, which is the normal state for
/// an engine that has none. It stays optional all the way from `browsingDatabase` so it can be
/// compared against the equally optional active database: an empty string here read as "some
/// database called nothing", never equal to nil, and fired a database switch on every click.
///
/// It lives beside the models rather than beside the tree because it is what a queued Truncate or
/// Drop is aimed at, and what the tab reconciliation after one matches against. Those used to hold
/// a bare name, and a bare name cannot name a table: `orders` exists in every database on the
/// server, the queue lives on the connection rather than on a tab, and the browse cursor moves
/// freely while something is queued, so the queue resolved against whatever the selected tab
/// happened to point at when Save ran.
struct DatabaseTreeTableRef: Hashable, Identifiable, Sendable {
    let database: String?
    let schema: String?
    let table: TableInfo

    init(database: String?, schema: String?, table: TableInfo) {
        self.database = database?.nilIfEmpty
        self.schema = schema?.nilIfEmpty
        self.table = table
    }

    /// The separator is escaped because every part of this is a user-chosen identifier and a
    /// quoted one may contain anything. Joined raw, schema `a|b` with table `c` and schema `a`
    /// with table `b|c` produced one id for two objects, and this id keys the outline's rows.
    var id: String {
        "\(Self.escaped(database))|\(Self.escaped(schema))|\(Self.escaped(table.id))"
    }

    /// The schema the statement should qualify with, which is the row's own before the table's.
    /// A hierarchical tree hangs its tables off a schema node and the `TableInfo` under it may
    /// carry none, while a flat list gets it the other way round.
    var qualifyingSchema: String? {
        schema ?? table.schema?.nilIfEmpty
    }

    private static func escaped(_ value: String?) -> String {
        (value ?? "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
    }
}
