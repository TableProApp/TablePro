//
//  PostgreSQLTableAttributes.swift
//  PostgreSQLDriverPlugin
//
//  The labelled properties the Properties tab shows for a PostgreSQL table.
//

import Foundation
import TableProPluginKit

/// The schema is deliberately absent: the app already knows which schema the tab is bound to and
/// labels it itself, so naming it here would print the same row twice.
enum PostgreSQLTableAttributes {
    static func build(
        owner: String?,
        tablespace: String?,
        persistence: String?,
        relkind: String?
    ) -> [PluginObjectAttribute] {
        var attributes: [PluginObjectAttribute] = []
        if let owner, !owner.isEmpty {
            attributes.append(PluginObjectAttribute(label: String(localized: "Owner"), value: owner))
        }
        if let tablespace, !tablespace.isEmpty {
            attributes.append(PluginObjectAttribute(label: String(localized: "Tablespace"), value: tablespace))
        }
        if let label = persistenceLabel(persistence) {
            attributes.append(PluginObjectAttribute(label: String(localized: "Persistence"), value: label))
        }
        if let label = relkindLabel(relkind) {
            attributes.append(PluginObjectAttribute(label: String(localized: "Kind"), value: label))
        }
        return attributes
    }

    /// `COMMENT ON TABLE` is refused on anything that is not an ordinary or partitioned table, and
    /// PostgreSQL spells the rest with their own keywords (`VIEW`, `MATERIALIZED VIEW`,
    /// `FOREIGN TABLE`). The app cannot tell those apart from a table, so the relation itself says
    /// so here. An unreadable `relkind` is treated as read-only rather than guessed at.
    static func commentIsReadOnly(relkind: String?) -> Bool {
        guard let relkind else { return true }
        return relkind != "r" && relkind != "p"
    }

    /// `pg_class.relpersistence`, documented as p (permanent), u (unlogged) and t (temporary).
    private static func persistenceLabel(_ value: String?) -> String? {
        switch value {
        case "p": String(localized: "Permanent")
        case "u": String(localized: "Unlogged")
        case "t": String(localized: "Temporary")
        default: nil
        }
    }

    /// `pg_class.relkind`. An ordinary table is the assumption already, so only a relation that
    /// differs from it is named, and an unfamiliar kind is left off rather than reported as a
    /// single letter.
    private static func relkindLabel(_ value: String?) -> String? {
        switch value {
        case "p": String(localized: "Partitioned table")
        case "v": String(localized: "View")
        case "m": String(localized: "Materialized view")
        case "f": String(localized: "Foreign table")
        default: nil
        }
    }
}
