//
//  PluginExportTypes.swift
//  TableProPluginKit
//

import Foundation

public struct PluginExportTable: Sendable {
    public let name: String
    public let databaseName: String
    public let schema: String?
    public let tableType: String
    public let optionValues: [Bool]

    /// What this item is. Defaults to `.table` for every caller that predates object scope, and is
    /// derived from `tableType` by the initializers that do not take one.
    public let kind: PluginExportObjectKind

    /// Whatever the driver needs to address this exact object again: a routine's oid or argument
    /// signature, a trigger's owning table. Opaque here, handed straight back to the driver.
    public let identity: String?

    /// The table a trigger fires for. Nil for every other kind.
    public let parentTable: String?

    /// Which rows and columns of this object to write. Unrestricted unless the user narrowed it.
    public let rowScope: PluginExportRowScope

    public init(
        name: String,
        databaseName: String,
        tableType: String,
        optionValues: [Bool] = [],
        schema: String?,
        kind: PluginExportObjectKind,
        identity: String? = nil,
        parentTable: String? = nil,
        rowScope: PluginExportRowScope = .unrestricted
    ) {
        self.name = name
        self.databaseName = databaseName
        self.schema = schema
        self.tableType = tableType
        self.optionValues = optionValues
        self.kind = kind
        self.identity = identity
        self.parentTable = parentTable
        self.rowScope = rowScope
    }

    /// Kept at its exact published signature. Adding a parameter to it, even a defaulted one,
    /// replaces its mangled symbol and every already-built plugin fails to load.
    @_disfavoredOverload
    public init(
        name: String,
        databaseName: String,
        tableType: String,
        optionValues: [Bool] = [],
        schema: String?
    ) {
        self.name = name
        self.databaseName = databaseName
        self.schema = schema
        self.tableType = tableType
        self.optionValues = optionValues
        self.kind = PluginExportObjectKind.from(tableType: tableType)
        self.identity = nil
        self.parentTable = nil
        self.rowScope = .unrestricted
    }

    @_disfavoredOverload
    public init(name: String, databaseName: String, tableType: String, optionValues: [Bool] = []) {
        self.name = name
        self.databaseName = databaseName
        self.schema = nil
        self.tableType = tableType
        self.optionValues = optionValues
        self.kind = PluginExportObjectKind.from(tableType: tableType)
        self.identity = nil
        self.parentTable = nil
        self.rowScope = .unrestricted
    }

    public var qualifiedName: String {
        databaseName.isEmpty ? name : "\(databaseName).\(name)"
    }

    /// The container this table was grouped under: the export tree's group name where it named
    /// one, and the driver's own schema where it did not. Two tables in one export carry the
    /// same value only when they really sit together, so this is what qualifies a bare name.
    public var containerName: String? {
        guard databaseName.isEmpty else { return databaseName }
        guard let schema, !schema.isEmpty else { return nil }
        return schema
    }
}

public struct PluginExportOptionColumn: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let width: CGFloat
    public let defaultValue: Bool

    public init(id: String, label: String, width: CGFloat, defaultValue: Bool = true) {
        self.id = id
        self.label = label
        self.width = width
        self.defaultValue = defaultValue
    }
}

public enum PluginExportError: LocalizedError {
    case fileWriteFailed(String)
    case encodingFailed
    case compressionFailed
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileWriteFailed(let path):
            return "Failed to write file: \(path)"
        case .encodingFailed:
            return "Failed to encode content as UTF-8"
        case .compressionFailed:
            return "Failed to compress data"
        case .exportFailed(let message):
            return "Export failed: \(message)"
        }
    }
}

public struct PluginExportCancellationError: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? { "Export cancelled" }
}

public struct PluginSequenceInfo: Sendable {
    public let name: String
    public let ddl: String
    public let ownedByTable: String?
    public let ownedByColumn: String?
    public let schema: String?

    public init(
        name: String,
        ddl: String,
        ownedByTable: String? = nil,
        ownedByColumn: String? = nil,
        schema: String? = nil
    ) {
        self.name = name
        self.ddl = ddl
        self.ownedByTable = ownedByTable
        self.ownedByColumn = ownedByColumn
        self.schema = schema
    }
}

public struct PluginEnumTypeInfo: Sendable {
    public let name: String
    public let labels: [String]

    public init(name: String, labels: [String]) {
        self.name = name
        self.labels = labels
    }
}

public struct ExportFormatResult: Sendable {
    public let warnings: [String]
    public init(warnings: [String] = []) {
        self.warnings = warnings
    }
}
