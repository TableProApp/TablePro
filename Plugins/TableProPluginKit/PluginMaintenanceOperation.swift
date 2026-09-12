//
//  PluginMaintenanceOperation.swift
//  TableProPluginKit
//

import Foundation

/// The kind of object a maintenance operation may name, spelled as `PluginTableInfo.type` is.
///
/// A struct rather than an enum, for the reason `DatabaseType` is one: a driver may report a kind
/// this framework never heard of, and `PluginDriverAdapter` already logs and falls back for exactly
/// that. An unknown spelling has to compare unequal to every known kind rather than fail to exist.
///
/// The raw value is uppercased on the way in so a driver that answers `"view"` and one that answers
/// `"VIEW"` land on the same kind.
public struct PluginObjectKind: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue.uppercased()
    }

    public init(_ name: String) {
        self.init(rawValue: name)
    }

    public static let table = PluginObjectKind(rawValue: "TABLE")
    public static let partitionedTable = PluginObjectKind(rawValue: "PARTITIONED TABLE")
    public static let view = PluginObjectKind(rawValue: "VIEW")
    public static let materializedView = PluginObjectKind(rawValue: "MATERIALIZED VIEW")
    public static let foreignTable = PluginObjectKind(rawValue: "FOREIGN TABLE")
    public static let systemTable = PluginObjectKind(rawValue: "SYSTEM TABLE")
    public static let externalTable = PluginObjectKind(rawValue: "EXTERNAL TABLE")

    /// Every kind the object browser lists as a table row.
    ///
    /// What a driver that answers only the older `supportedMaintenanceOperations()` inherits, so its
    /// menu keeps exactly the shape it had before kinds existed.
    public static let allTableLike: Set<PluginObjectKind> = [
        .table,
        .partitionedTable,
        .view,
        .materializedView,
        .foreignTable,
        .systemTable,
        .externalTable
    ]
}

/// What an operation's statement may name.
///
/// SQLite's `VACUUM` and `PRAGMA integrity_check` take no object at all, so an operation list of
/// bare names cannot say that the table the sheet printed beside them was never in the statement.
public enum PluginMaintenanceScope: String, Sendable, Codable {
    case object
    case database
    case objectOrDatabase

    /// Whether a statement for this operation may name one object.
    public var admitsObject: Bool {
        switch self {
        case .object, .objectOrDatabase: return true
        case .database: return false
        }
    }

    /// Whether a statement for this operation may name no object and act on the whole database.
    public var admitsDatabase: Bool {
        switch self {
        case .database, .objectOrDatabase: return true
        case .object: return false
        }
    }
}

/// One option an operation accepts, as the driver that builds the statement declares it.
///
/// Declared rather than assumed because the confirmation sheet used to decide this itself, gated on
/// two engine names: an engine that grew the same flags would not have been offered them, and the
/// keys the sheet produced had to agree by hand with the keys the driver read.
public struct PluginMaintenanceOption: Hashable, Sendable, Codable {
    /// The key this option's value travels under in the `options` dictionary.
    public let key: String
    public let label: String
    public let defaultValue: String
    /// The fixed set of values, or nil for a boolean the caller sends as `"true"` or `"false"`.
    public let choices: [String]?

    public init(key: String, label: String, defaultValue: String, choices: [String]? = nil) {
        self.key = key
        self.label = label
        self.defaultValue = defaultValue
        self.choices = choices
    }

    public var isToggle: Bool { choices == nil }
}

/// One maintenance operation, with everything the caller needs to decide whether to offer it.
///
/// The older `supportedMaintenanceOperations()` answers a list of bare names, which cannot say which
/// objects an operation works on. PostgreSQL answers `VACUUM` on a view with a WARNING and the
/// success command tag `VACUUM`, so the app reported success over work the server skipped, while
/// `REINDEX` on the same view failed outright.
public struct PluginMaintenanceOperation: Hashable, Sendable, Codable {
    public let name: String
    public let appliesTo: Set<PluginObjectKind>
    public let scope: PluginMaintenanceScope
    public let options: [PluginMaintenanceOption]

    public init(
        name: String,
        appliesTo: Set<PluginObjectKind>,
        scope: PluginMaintenanceScope,
        options: [PluginMaintenanceOption] = []
    ) {
        self.name = name
        self.appliesTo = appliesTo
        self.scope = scope
        self.options = options
    }

    /// Whether a statement for this operation may name an object of `kind`.
    public func applies(to kind: PluginObjectKind) -> Bool {
        scope.admitsObject && appliesTo.contains(kind)
    }

    /// The object a statement for this operation should name, given the object it was reached from.
    ///
    /// Nil for an operation that acts on the whole database, so the object is dropped rather than
    /// printed beside a statement that never mentions it: the sheet showed `VACUUM orders` on SQLite
    /// where `VACUUM` ran.
    public func target(_ objectName: String?) -> String? {
        scope.admitsObject ? objectName : nil
    }

    /// Every option's default, which is what a caller sends when the user changes nothing.
    public var defaultOptionValues: [String: String] {
        var values: [String: String] = [:]
        for option in options {
            values[option.key] = option.defaultValue
        }
        return values
    }

    /// Lifts a driver's older list of bare names into descriptors.
    ///
    /// What `PluginDatabaseDriver.maintenanceOperations()` defaults to, so a plugin built before kinds
    /// existed keeps exactly the behaviour it had: every table-like kind, either scope, no options.
    public static func lifting(_ names: [String]) -> [PluginMaintenanceOperation] {
        names.map {
            PluginMaintenanceOperation(
                name: $0,
                appliesTo: PluginObjectKind.allTableLike,
                scope: .objectOrDatabase
            )
        }
    }
}
