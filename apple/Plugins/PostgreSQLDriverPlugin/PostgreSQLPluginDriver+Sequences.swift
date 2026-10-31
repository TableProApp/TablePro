//
//  PostgreSQLPluginDriver+Sequences.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import os
import TableProPluginKit
import TableProPostgreSQLCore

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

    func fetchSequenceDetails(sequence: String, schema: String?) async throws -> PluginSequenceDetails? {
        let schemaName = schema ?? core.currentSchema
        let definitions = try await sequenceDefinitions(schema: schemaName, dependentOnTable: nil, named: sequence)
        guard let definition = definitions.first else { return nil }
        return definition.details(schema: schemaName, position: await position(schema: schemaName, sequence: sequence))
    }

    // Needs SELECT on the sequence; a role without it gets no position rather than a guess.
    private func position(schema: String, sequence: String) async -> PostgreSQLSequencePosition? {
        do {
            let query = PostgreSQLSequencePosition.query(schema: schema, sequence: sequence)
            return PostgreSQLSequencePosition(row: try await catalogRead(query).rows.first)
        } catch {
            Self.sequenceLogger.debug(
                "Sequence position unavailable for \(sequence, privacy: .public): \(error.localizedDescription)"
            )
            return nil
        }
    }

    func sequenceDDL(sequence: String, schema: String) async throws -> String? {
        let definitions = try await sequenceDefinitions(schema: schema, dependentOnTable: nil, named: sequence)
        return definitions.first?.qualifiedDDL(schema: schema)
    }

    func sequenceNextValueStatement(
        for sequence: PluginSequenceDetails,
        nextValue: PluginSequenceNextValue
    ) -> String? {
        PostgreSQLSequenceStatements.nextValue(
            sequence,
            schema: sequence.schema ?? core.currentSchema,
            nextValue: nextValue,
            hasRowSecurity: versionedCapabilities.hasBypassRLS
        )
    }

    func alterSequenceStatement(
        for sequence: PluginSequenceDetails,
        settings: PluginSequenceSettings
    ) -> String? {
        PostgreSQLSequenceStatements.alter(sequence, schema: sequence.schema ?? core.currentSchema, settings: settings)
    }

    func createSequenceTemplate() -> String? {
        PostgreSQLSequenceStatements.createTemplate
    }

    private func sequenceDefinitions(
        schema: String,
        dependentOnTable table: String?,
        named sequence: String? = nil
    ) async throws -> [PostgreSQLSequenceDefinition] {
        let source = PostgreSQLSequenceQueries.source(hasSequencesCatalog: includesSequencesCatalog())
        let listing = try await catalogRead(
            PostgreSQLSequenceQueries.sequenceList(schema: schema, dependentOnTable: table, source: source, named: sequence)
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
            return try await catalogRead(query).rows.first?[safe: 0]?.asText
        } catch {
            Self.sequenceLogger.debug(
                "Sequence last value unavailable for \(sequence, privacy: .public): \(error.localizedDescription)"
            )
            return nil
        }
    }
}
