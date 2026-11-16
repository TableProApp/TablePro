//
//  PostgreSQLPluginDriver+Sequences.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProPostgreSQLCore

extension PostgreSQLPluginDriver {
    func fetchDependentSequences(table: String, schema: String?) async throws -> [(name: String, ddl: String)] {
        try await exportCatalog.fetchDependentSequences(table: table, schema: schema)
    }

    func fetchSequences(schema: String?) async throws -> [PluginSequenceInfo] {
        try await exportCatalog.fetchSequences(schema: schema)
    }

    func fetchSequenceDetails(sequence: String, schema: String?) async throws -> PluginSequenceDetails? {
        try await exportCatalog.fetchSequenceDetails(sequence: sequence, schema: schema)
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
}
