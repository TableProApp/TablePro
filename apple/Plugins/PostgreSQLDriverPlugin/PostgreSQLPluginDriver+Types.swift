//
//  PostgreSQLPluginDriver+Types.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProPostgreSQLCore

extension PostgreSQLPluginDriver {
    func fetchUserDefinedTypes(schema: String?) async throws -> [PluginUserDefinedTypeInfo] {
        try await exportCatalog.fetchUserDefinedTypes(schema: schema)
    }

    func fetchUserDefinedTypes(inSchemas schemas: [String]) async throws -> [PluginUserDefinedTypeInfo]? {
        guard !schemas.isEmpty else { return [] }
        let query = PostgreSQLObjectQueries.userDefinedTypeList(schemas: schemas, capabilities: catalogCapabilities)
        let result = try await catalogRead(query)
        return result.rows
            .compactMap(PostgreSQLTypeDefinition.record(from:))
            .map(PostgreSQLTypeDefinition.info(from:))
    }

    func fetchUserDefinedType(_ type: PluginUserDefinedTypeInfo) async throws -> PluginUserDefinedTypeInfo {
        try await exportCatalog.fetchUserDefinedType(type)
    }

    func createTypeTemplate(schema: String?) -> String? {
        PostgreSQLObjectQueries.createTypeTemplate(schema: schema ?? currentSchema ?? "public")
    }

    func generateDropTypeSQL(type: PluginUserDefinedTypeInfo) -> String? {
        PostgreSQLObjectQueries.dropType(
            schema: type.schema ?? currentSchema ?? "public",
            name: type.name,
            kind: type.kind
        )
    }

    func generateDropTypeSQL(type: PluginUserDefinedTypeInfo, cascade: Bool) -> String? {
        PostgreSQLTypeStatements.drop(
            schema: type.schema ?? currentSchema ?? "public",
            name: type.name,
            kind: type.kind,
            cascade: cascade
        )
    }

    func createUserDefinedTypeStatements(_ definition: PluginUserDefinedTypeDefinition) -> [String]? {
        PostgreSQLTypeStatements.create(definition, schema: definition.schema ?? currentSchema ?? "public")
    }

    func alterUserDefinedTypeStatements(
        type: PluginUserDefinedTypeInfo,
        change: PluginUserDefinedTypeChange
    ) -> [String]? {
        PostgreSQLTypeStatements.alter(
            type: type,
            schema: type.schema ?? currentSchema ?? "public",
            change: change,
            capabilities: versionedCapabilities
        )
    }

    func userDefinedTypeChangeRunsOutsideTransaction(_ change: PluginUserDefinedTypeChange) -> Bool {
        PostgreSQLTypeStatements.runsOutsideTransaction(change, capabilities: versionedCapabilities)
    }

    func generateAddEnumLabelSQL(
        type: PluginUserDefinedTypeInfo,
        label: String,
        placement: PluginEnumLabelPlacement?
    ) -> String? {
        guard type.kind == .enumeration else { return nil }
        if placement != nil, !versionedCapabilities.hasEnumLabelPlacement { return nil }
        return PostgreSQLObjectQueries.addEnumLabel(
            schema: type.schema ?? currentSchema ?? "public",
            name: type.name,
            label: label,
            placement: placement,
            ifNotExists: versionedCapabilities.hasEnumAddValueIfNotExists
        )
    }

    func generateRenameEnumLabelSQL(
        type: PluginUserDefinedTypeInfo,
        from oldLabel: String,
        to newLabel: String
    ) -> String? {
        guard type.kind == .enumeration, versionedCapabilities.hasRenameEnumValue else { return nil }
        return PostgreSQLObjectQueries.renameEnumLabel(
            schema: type.schema ?? currentSchema ?? "public",
            name: type.name,
            from: oldLabel,
            to: newLabel
        )
    }
}
