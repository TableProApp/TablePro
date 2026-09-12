//
//  PostgreSQLPluginDriver+Sequences.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import os
import TableProPluginKit

extension PostgreSQLPluginDriver {
    static let sequenceLogger = Logger(subsystem: "com.TablePro.PostgreSQLDriver", category: "Sequences")

    func fetchDependentSequences(table: String, schema: String?) async throws -> [(name: String, ddl: String)] {
        let definitions = try await sequenceDefinitions(schema: schema ?? core.currentSchema, dependentOnTable: table)
        return definitions.map { (name: $0.name, ddl: $0.ddl) }
    }

    func fetchSequences(schema: String?) async throws -> [PluginSequenceInfo] {
        let schemaName = schema ?? core.currentSchema
        let definitions = try await sequenceDefinitions(schema: schemaName, dependentOnTable: nil)
        return definitions.map { PluginSequenceInfo(name: $0.name, ddl: $0.ddl, schema: schemaName) }
    }

    private func sequenceDefinitions(
        schema: String,
        dependentOnTable table: String?
    ) async throws -> [PostgreSQLSequenceDefinition] {
        let source = PostgreSQLSequenceQueries.source(hasSequencesCatalog: includesSequencesCatalog())
        let listing = try await execute(
            query: PostgreSQLSequenceQueries.sequenceList(schema: schema, dependentOnTable: table, source: source)
        )
        var definitions: [PostgreSQLSequenceDefinition] = []
        for definition in PostgreSQLSequenceQueries.definitions(from: listing.rows) {
            guard definition.needsLastValueRead else {
                definitions.append(definition)
                continue
            }
            definitions.append(definition.withLastValue(await lastValue(schema: schema, sequence: definition.name)))
        }
        return definitions
    }

    private func lastValue(schema: String, sequence: String) async -> String? {
        do {
            let query = PostgreSQLSequenceQueries.lastValue(schema: schema, sequence: sequence)
            return try await execute(query: query).rows.first?[safe: 0]?.asText
        } catch {
            Self.sequenceLogger.debug(
                "Sequence last value unavailable for \(sequence, privacy: .public): \(error.localizedDescription)"
            )
            return nil
        }
    }
}
