//
//  PostgreSQLPluginDriver+CatalogSideObjects.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProPostgreSQLCore

extension PostgreSQLPluginDriver {
    // Every side kind as one simple Query, under one `SET LOCAL search_path`: one round trip where the kinds asked one
    // at a time cost one each. The server stops at the first statement that fails, and the core sends each read it
    // never reached alone, so every kind still fails alone. Each kind reads and parses as its own fetch does.
    func fetchCatalogSideObjects(_ request: PluginCatalogSideRequest) async -> PluginCatalogSideObjects {
        let schema = request.schema ?? core.currentSchema
        let listsExtensions = request.serverObjectKinds.contains(PostgreSQLExtensions.kindId)
            && serverObjectKinds.contains { $0.id == PostgreSQLExtensions.kindId }
        var reads: [PostgreSQLCatalogRead] = []
        func place(_ statement: String) -> Int {
            reads.append(PostgreSQLCatalogRead(statement: statement))
            return reads.count - 1
        }
        let schemasAt = request.schemas ? place(PostgreSQLSchemaQueries.listSchemas) : nil
        let routinesAt = request.routines
            ? place(PostgreSQLObjectQueries.routineList(schema: schema, capabilities: catalogCapabilities))
            : nil
        let triggersAt = request.triggers ? place(PostgreSQLObjectQueries.triggerList(schema: schema, table: nil)) : nil
        let typesAt = request.userDefinedTypes
            ? place(PostgreSQLObjectQueries.userDefinedTypeList(schema: schema, identity: nil, capabilities: catalogCapabilities))
            : nil
        let extensionsAt = listsExtensions ? place(PostgreSQLExtensionQueries.list) : nil

        let answers = reads.isEmpty ? [] : await core.executeCatalogReads(reads)
        func rows(_ index: Int) -> Result<[[PluginCellValue]], any Error> {
            answers[index].map(\.rows)
        }

        var objects = PluginCatalogSideObjects()
        if let schemasAt {
            objects.schemas = rows(schemasAt).map { $0.compactMap { row in row.first?.asText } }
        }
        if let routinesAt {
            objects.routines = rows(routinesAt).map { listed in
                listed.compactMap { PostgreSQLCatalogExport.routine(from: $0, fallbackSchema: schema) }
            }
        }
        if let triggersAt {
            objects.triggers = rows(triggersAt).map { listed in
                listed.compactMap { PostgreSQLCatalogExport.trigger(from: $0, fallbackSchema: schema) }
            }
        }
        if let typesAt {
            objects.userDefinedTypes = rows(typesAt).map { listed in
                listed.compactMap(PostgreSQLTypeDefinition.record(from:)).map(PostgreSQLTypeDefinition.info(from:))
            }
        }
        // A kind this driver does not list answers empty, as `fetchServerObjects` does.
        for kindId in request.serverObjectKinds {
            guard kindId == PostgreSQLExtensions.kindId, let extensionsAt else {
                objects.serverObjects[kindId] = .success([])
                continue
            }
            objects.serverObjects[kindId] = rows(extensionsAt).map { listed in
                listed.compactMap { PostgreSQLExtensionQueries.object(from: $0) }
            }
        }
        return objects
    }
}
