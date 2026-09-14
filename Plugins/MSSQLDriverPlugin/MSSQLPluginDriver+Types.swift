//
//  MSSQLPluginDriver+Types.swift
//  MSSQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension MSSQLPluginDriver {
    /// The listing is one query and carries no definitions: a table type's statement needs two more
    /// round trips per type, and a schema with a hundred types would pay for all of them to draw a
    /// list of names. `fetchUserDefinedType` fills in the definition for the one the reader opens.
    func fetchUserDefinedTypes(schema: String?) async throws -> [PluginUserDefinedTypeInfo] {
        let resolvedSchema = effectiveSchema(schema)
        let result = try await execute(query: MSSQLTypeQueries.userDefinedTypeList(schema: resolvedSchema))
        return result.rows.compactMap { row in
            listedType(from: row, schema: resolvedSchema)
        }
    }

    /// Addressed by `user_type_id`, so a type renamed since the listing still resolves, and the kind
    /// is never part of the lookup.
    func fetchUserDefinedType(_ type: PluginUserDefinedTypeInfo) async throws -> PluginUserDefinedTypeInfo {
        let resolvedSchema = effectiveSchema(type.schema)
        let result = try await execute(query: MSSQLTypeQueries.userDefinedTypeList(schema: resolvedSchema))
        let listed = result.rows.compactMap { listedType(from: $0, schema: resolvedSchema) }
        let match = type.identity.flatMap { identity in listed.first { $0.identity == identity } }
            ?? listed.first { $0.name == type.name }
        guard let match else { throw PluginObjectSourceError.notFound(type.name) }

        switch match.kind {
        case .tableType:
            return try await tableType(match, schema: resolvedSchema)
        case .clrType:
            return match.withDefinition(MSSQLTypeDefinition.clrStatement(
                schema: resolvedSchema,
                name: match.name,
                assembly: match.attributes.first { $0.label == "Assembly" }?.value,
                assemblyClass: match.attributes.first { $0.label == "Class" }?.value
            ))
        default:
            return match.withDefinition(MSSQLTypeDefinition.aliasStatement(
                schema: resolvedSchema,
                name: match.name,
                baseType: match.baseType,
                isNullable: match.attributes.first { $0.label == "Nullable" }?.value != "NO"
            ))
        }
    }

    private func tableType(
        _ type: PluginUserDefinedTypeInfo,
        schema: String
    ) async throws -> PluginUserDefinedTypeInfo {
        let columnRows = try await execute(
            query: MSSQLTypeQueries.tableTypeColumns(schema: schema, name: type.name)
        ).rows
        let indexRows = try await execute(
            query: MSSQLTypeQueries.tableTypeIndexes(schema: schema, name: type.name)
        ).rows
        let checkRows = try await execute(
            query: MSSQLTypeQueries.tableTypeCheckConstraints(schema: schema, name: type.name)
        ).rows
        let collation = try? await execute(query: MSSQLTypeQueries.databaseCollation).rows.first?[safe: 0]?.asText

        let columns = columnRows.compactMap { row -> MSSQLTypeDefinition.Column? in
            guard let name = row[safe: 0]?.asText else { return nil }
            return MSSQLTypeDefinition.Column(
                name: name,
                type: row[safe: 1]?.asText,
                isNullable: row[safe: 2]?.asText == "1",
                identitySpec: row[safe: 3]?.asText,
                computedDefinition: row[safe: 4]?.asText,
                defaultDefinition: row[safe: 5]?.asText,
                collation: row[safe: 6]?.asText
            )
        }
        var indexOrder: [String] = []
        var indexesById: [String: MSSQLTypeDefinition.Index] = [:]
        for row in indexRows {
            guard let indexId = row[safe: 6]?.asText, let column = row[safe: 4]?.asText else { continue }
            let key = MSSQLTypeDefinition.IndexKey(column: column, isDescending: row[safe: 5]?.asText == "1")
            if let existing = indexesById[indexId] {
                indexesById[indexId] = MSSQLTypeDefinition.Index(
                    name: existing.name,
                    isPrimaryKey: existing.isPrimaryKey,
                    isUnique: existing.isUnique,
                    typeDescription: existing.typeDescription,
                    keys: existing.keys + [key],
                    bucketCount: existing.bucketCount
                )
                continue
            }
            indexOrder.append(indexId)
            indexesById[indexId] = MSSQLTypeDefinition.Index(
                name: row[safe: 0]?.asText,
                isPrimaryKey: row[safe: 1]?.asText == "1",
                isUnique: row[safe: 2]?.asText == "1",
                typeDescription: row[safe: 3]?.asText,
                keys: [key],
                bucketCount: row[safe: 7]?.asText.flatMap(Int.init) ?? 0
            )
        }
        let indexes = indexOrder.compactMap { indexesById[$0] }
        let checks = checkRows.compactMap { $0[safe: 0]?.asText }

        return PluginUserDefinedTypeInfo(
            name: type.name,
            kind: .tableType,
            schema: schema,
            identity: type.identity,
            fields: columns.map {
                PluginUserDefinedTypeField(name: $0.name, type: $0.type ?? "", collation: $0.collation)
            },
            columnTypeSpelling: type.columnTypeSpelling,
            definition: MSSQLTypeDefinition.tableStatement(
                schema: schema,
                name: type.name,
                columns: columns,
                indexes: indexes,
                checkConstraints: checks,
                isMemoryOptimized: type.attributes.contains { $0.label == "Memory Optimized" && $0.value == "YES" },
                databaseCollation: collation ?? nil
            ),
            attributes: type.attributes
        )
    }

    private func listedType(from row: [PluginCellValue], schema: String) -> PluginUserDefinedTypeInfo? {
        guard let name = row[safe: 0]?.asText else { return nil }
        let kindCode = row[safe: 3]?.asText ?? ""
        let kind: PluginUserDefinedTypeKind = switch MSSQLTypeQueries.Kind(rawValue: kindCode) {
        case .table: .tableType
        case .clr: .clrType
        default: .aliasType
        }

        var attributes: [PluginObjectAttribute] = []
        if kind == .aliasType {
            attributes.append(PluginObjectAttribute(
                label: "Nullable",
                value: row[safe: 5]?.asText == "1" ? "YES" : "NO"
            ))
        }
        if let collation = row[safe: 6]?.asText, !collation.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Collation", value: collation))
        }
        if let assembly = row[safe: 7]?.asText, !assembly.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Assembly", value: assembly))
        }
        if let assemblyClass = row[safe: 8]?.asText, !assemblyClass.isEmpty {
            attributes.append(PluginObjectAttribute(label: "Class", value: assemblyClass))
        }
        if kind == .tableType, row[safe: 9]?.asText == "1" {
            attributes.append(PluginObjectAttribute(label: "Memory Optimized", value: "YES"))
        }

        return PluginUserDefinedTypeInfo(
            name: name,
            kind: kind,
            schema: row[safe: 1]?.asText ?? schema,
            identity: row[safe: 2]?.asText,
            baseType: row[safe: 4]?.asText,
            columnTypeSpelling: columnTypeSpelling(kind: kind, schema: row[safe: 1]?.asText ?? schema, name: name),
            attributes: attributes
        )
    }

    /// A table type is never a column type, so it gets no spelling at all rather than one the
    /// column picker would offer and the server would reject.
    private func columnTypeSpelling(kind: PluginUserDefinedTypeKind, schema: String, name: String) -> String? {
        guard kind != .tableType else { return nil }
        return "\(MSSQLTypeDefinition.bracketed(schema)).\(MSSQLTypeDefinition.bracketed(name))"
    }
}

private extension PluginUserDefinedTypeInfo {
    func withDefinition(_ definition: String) -> PluginUserDefinedTypeInfo {
        PluginUserDefinedTypeInfo(
            name: name,
            kind: kind,
            schema: schema,
            identity: identity,
            enumLabels: enumLabels,
            fields: fields,
            baseType: baseType,
            columnTypeSpelling: columnTypeSpelling,
            definition: definition,
            attributes: attributes
        )
    }
}
