//
//  CloudflareR2SQLMetadataParityTests.swift
//  TableProTests
//
//  The app shows Cloudflare R2 SQL in the database picker, form and editor before its registry
//  plugin is installed, from a curated copy of the plugin's metadata. `CloudflareR2SQLMetadata` is
//  the plugin's own file, compiled into this target, so the two copies are compared here instead of
//  drifting apart until the plugin loads and silently replaces one with the other.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Cloudflare R2 SQL curated metadata parity")
struct CloudflareR2SQLMetadataParityTests {
    private func curated() throws -> PluginMetadataSnapshot {
        try #require(
            PluginMetadataRegistry.shared.builtInDefaults().first { $0.typeId == "Cloudflare R2 SQL" }?.snapshot
        )
    }

    @Test("Identity and schema vocabulary match the plugin")
    func identity() throws {
        let snapshot = try curated()

        #expect(snapshot.displayName == CloudflareR2SQLMetadata.displayName)
        #expect(snapshot.iconName == CloudflareR2SQLMetadata.iconName)
        #expect(snapshot.brandColorHex == CloudflareR2SQLMetadata.brandColorHex)
        #expect(snapshot.schema.defaultSchemaName == CloudflareR2SQLMetadata.defaultSchemaName)
        #expect(snapshot.schema.schemaEntityName == CloudflareR2SQLMetadata.schemaEntityName)
        #expect(snapshot.schema.containerEntityName == CloudflareR2SQLMetadata.containerEntityName)
        #expect(snapshot.schema.structureColumnFields == CloudflareR2SQLMetadata.structureColumnFields)
    }

    @Test("Editor metadata matches the plugin")
    func editor() throws {
        let snapshot = try curated()
        let dialect = try #require(snapshot.editor.sqlDialect)
        let shipped = CloudflareR2SQLMetadata.dialect

        #expect(dialect.identifierQuote == shipped.identifierQuote)
        #expect(dialect.keywords == shipped.keywords)
        #expect(dialect.functions == shipped.functions)
        #expect(dialect.dataTypes == shipped.dataTypes)
        #expect(dialect.paginationStyle == shipped.paginationStyle)
        #expect(dialect.booleanLiteralStyle == shipped.booleanLiteralStyle)
        #expect(dialect.likeEscapeStyle == shipped.likeEscapeStyle)
        #expect(dialect.regexSyntax == shipped.regexSyntax)
        #expect(snapshot.editor.columnTypesByCategory == CloudflareR2SQLMetadata.columnTypesByCategory)
        #expect(snapshot.editor.statementCompletions.map { [$0.label, $0.insertText] }
            == CloudflareR2SQLMetadata.statementCompletions.map { [$0.label, $0.insertText] })
        #expect(snapshot.explainVariants.map { [$0.id, $0.label, $0.sqlPrefix] }
            == CloudflareR2SQLMetadata.explainVariants.map { [$0.id, $0.label, $0.sqlPrefix] })
    }

    @Test("Connection fields match the plugin")
    func connectionFields() throws {
        let fields = try curated().connection.additionalConnectionFields
        let shipped = CloudflareR2SQLMetadata.connectionFields

        #expect(fields.map(\.id) == shipped.map(\.id))
        #expect(fields.map(\.label) == shipped.map(\.label))
        #expect(fields.map(\.placeholder) == shipped.map(\.placeholder))
        #expect(fields.map(\.isRequired) == shipped.map(\.isRequired))
        #expect(fields.map(\.section) == shipped.map(\.section))
    }

    @Test("The app-only capabilities describe a read-only engine that cannot skip rows")
    func appOnlyCapabilities() throws {
        let capabilities = try curated().capabilities

        #expect(capabilities.isEngineReadOnly)
        #expect(capabilities.pagination == .leadingRowsOnly(maximumRows: 10_000))
    }
}
