//
//  PostgreSQLPluginDriver+Extensions.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProPostgreSQLCore

extension PostgreSQLPluginDriver {
    // `serverObjectKinds` is dynamically dispatched, so a subclass that declares none reads nothing here.
    func fetchServerObjects(ofKind kindId: String, schema: String?) async throws -> [PluginServerObjectInfo] {
        guard kindId == PostgreSQLExtensions.kindId, serverObjectKinds.contains(where: { $0.id == kindId }) else {
            return []
        }
        let result = try await catalogRead(PostgreSQLExtensionQueries.list)
        return result.rows.compactMap { PostgreSQLExtensionQueries.object(from: $0) }
    }

    // Read again by the oid this driver handed out, which a rename or a schema move keeps; anything
    // else is refused rather than widened into a lookup by name.
    func fetchServerObject(_ object: PluginServerObjectInfo) async throws -> PluginServerObjectInfo {
        guard object.kindId == PostgreSQLExtensions.kindId else { throw PluginObjectSourceError.unsupported(object.name) }
        guard let identity = object.identity, let oid = UInt32(identity) else {
            throw PluginObjectSourceError.notFound(object.name)
        }
        let result = try await catalogRead(PostgreSQLExtensionQueries.one(oid: oid))
        guard let row = result.rows.first(where: { $0[safe: 0]?.asText == String(oid) }),
              let name = row[safe: 1]?.asText
        else { throw PluginObjectSourceError.notFound(object.name) }
        let defaultVersion = try? await catalogRead(PostgreSQLExtensionQueries.defaultVersion(name: name))
        guard let fresh = PostgreSQLExtensionQueries.object(
            from: row,
            defaultVersion: defaultVersion?.rows.first?[safe: 0]?.asText
        ) else { throw PluginObjectSourceError.notFound(object.name) }
        return fresh
    }
}
