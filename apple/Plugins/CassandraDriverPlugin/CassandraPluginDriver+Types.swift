//
//  CassandraPluginDriver+Types.swift
//  CassandraDriverPlugin
//

import Foundation
import TableProPluginKit

extension CassandraPluginDriver {
    func fetchUserDefinedTypes(schema: String?) async throws -> [PluginUserDefinedTypeInfo] {
        let keyspace = resolveKeyspace(schema)
        let result = try await execute(query: CassandraUserTypes.listQuery(keyspace: keyspace))
        return result.rows.compactMap { userType(from: $0, keyspace: keyspace) }
    }

    func fetchUserDefinedType(_ type: PluginUserDefinedTypeInfo) async throws -> PluginUserDefinedTypeInfo {
        let keyspace = resolveKeyspace(type.schema)
        let result = try await execute(query: CassandraUserTypes.typeQuery(keyspace: keyspace, name: type.name))
        let match = result.rows
            .compactMap { userType(from: $0, keyspace: keyspace) }
            .first { $0.name == type.name }
        guard let match else { throw PluginObjectSourceError.notFound(type.name) }
        return match
    }

    func generateDropTypeSQL(type: PluginUserDefinedTypeInfo) -> String? {
        CassandraUserTypes.dropStatement(keyspace: resolveKeyspace(type.schema), name: type.name)
    }

    private func userType(from row: [PluginCellValue], keyspace: String) -> PluginUserDefinedTypeInfo? {
        guard let name = row[safe: 0]?.asText else { return nil }
        let fields = CassandraUserTypes.fields(names: row[safe: 1]?.asText, types: row[safe: 2]?.asText)
        return PluginUserDefinedTypeInfo(
            name: name,
            kind: .udt,
            schema: keyspace,
            fields: (fields ?? []).map { PluginUserDefinedTypeField(name: $0.name, type: $0.type) },
            columnTypeSpelling: CassandraUserTypes.columnTypeSpelling(
                name: name,
                fields: fields,
                releaseVersion: serverVersion
            ),
            definition: fields.map { CassandraUserTypes.definition(keyspace: keyspace, name: name, fields: $0) }
        )
    }
}
