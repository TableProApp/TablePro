//
//  PostgreSQLPluginDriver+Types.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension PostgreSQLPluginDriver {
    func fetchUserDefinedTypes(schema: String?) async throws -> [PluginUserDefinedTypeInfo] {
        let resolvedSchema = schema ?? currentSchema ?? "public"
        let query = PostgreSQLObjectQueries.userDefinedTypeList(
            schema: resolvedSchema,
            identity: nil,
            serverVersionNumber: serverVersionNumber
        )
        let result = try await execute(query: query)
        return result.rows
            .compactMap(PostgreSQLTypeDefinition.record(from:))
            .map(PostgreSQLTypeDefinition.info(from:))
    }

    /// An identity is the oid this driver handed out, so one that is not an oid is refused rather
    /// than widened into a schema listing that would hand back whichever type sorts first. The
    /// oid is looked up without a schema predicate, because a type moved to another schema keeps
    /// it, and the row that comes back is checked against it before it is believed.
    func fetchUserDefinedType(_ type: PluginUserDefinedTypeInfo) async throws -> PluginUserDefinedTypeInfo {
        if let identity = type.identity {
            guard let oid = UInt32(identity) else { throw PluginObjectSourceError.notFound(type.name) }
            let query = PostgreSQLObjectQueries.userDefinedTypeList(
                schema: nil,
                identity: String(oid),
                serverVersionNumber: serverVersionNumber
            )
            let result = try await execute(query: query)
            let match = result.rows
                .compactMap(PostgreSQLTypeDefinition.record(from:))
                .first { $0.identity == String(oid) }
            guard let match else { throw PluginObjectSourceError.notFound(type.name) }
            return PostgreSQLTypeDefinition.info(from: match)
        }
        let resolvedSchema = type.schema ?? currentSchema ?? "public"
        let query = PostgreSQLObjectQueries.userDefinedTypeList(
            schema: resolvedSchema,
            identity: nil,
            serverVersionNumber: serverVersionNumber
        )
        let result = try await execute(query: query)
        let match = result.rows
            .compactMap(PostgreSQLTypeDefinition.record(from:))
            .first { $0.name == type.name }
        guard let match else { throw PluginObjectSourceError.notFound(type.name) }
        return PostgreSQLTypeDefinition.info(from: match)
    }

    func createTypeTemplate(schema: String?) -> String? {
        PostgreSQLObjectQueries.createTypeTemplate(schema: schema ?? currentSchema ?? "public")
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
