//
//  DynamoDBMetadataParityTests.swift
//  TableProTests
//
//  The app describes DynamoDB from a curated copy of the plugin's statics until the registry plugin
//  loads. `DynamoDBPlugin.swift` is compiled into this target, so the two copies are compared here
//  instead of drifting apart until the plugin silently replaces one with the other.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct DynamoDBMetadataParityTests {
    private func curated() throws -> PluginMetadataSnapshot {
        try #require(PluginMetadataRegistry.shared.builtInDefaults().first { $0.typeId == "DynamoDB" }?.snapshot)
    }

    @Test("Identity and structure editing match the plugin")
    func identityAndStructureEditing() throws {
        let snapshot = try curated()

        #expect(snapshot.displayName == DynamoDBPlugin.databaseDisplayName)
        #expect(snapshot.iconName == DynamoDBPlugin.iconName)
        #expect(snapshot.brandColorHex == DynamoDBPlugin.brandColorHex)
        #expect(snapshot.queryLanguageName == DynamoDBPlugin.queryLanguageName)
        #expect(snapshot.editorLanguage == DynamoDBPlugin.editorLanguage)
        #expect(snapshot.parameterStyle == DynamoDBPlugin.parameterStyle)
        #expect(snapshot.connectionMode == DynamoDBPlugin.connectionMode)
        #expect(snapshot.supportsSchemaEditing == DynamoDBPlugin.supportsSchemaEditing)
        #expect(snapshot.supportsForeignKeys == DynamoDBPlugin.supportsForeignKeys)
        #expect(snapshot.supportsDatabaseSwitching == DynamoDBPlugin.supportsDatabaseSwitching)
        #expect(snapshot.schema.structureColumnFields == DynamoDBPlugin.structureColumnFields)
        #expect(snapshot.schema.databaseGroupingStrategy == DynamoDBPlugin.databaseGroupingStrategy)
        #expect(snapshot.schema.defaultGroupName == DynamoDBPlugin.defaultGroupName)
        #expect(snapshot.schema.tableEntityName == DynamoDBPlugin.tableEntityName)
    }

    @Test("Structure capabilities match the plugin")
    func structureCapabilities() throws {
        let capabilities = try curated().capabilities

        #expect(capabilities.supportsAddColumn == DynamoDBPlugin.supportsAddColumn)
        #expect(capabilities.supportsModifyColumn == DynamoDBPlugin.supportsModifyColumn)
        #expect(capabilities.supportsDropColumn == DynamoDBPlugin.supportsDropColumn)
        #expect(capabilities.supportsRenameColumn == DynamoDBPlugin.supportsRenameColumn)
        #expect(capabilities.supportsModifyPrimaryKey == DynamoDBPlugin.supportsModifyPrimaryKey)
        #expect(capabilities.supportsAddIndex == DynamoDBPlugin.supportsAddIndex)
        #expect(capabilities.supportsDropIndex == DynamoDBPlugin.supportsDropIndex)
        #expect(capabilities.supportsImport == DynamoDBPlugin.supportsImport)
        #expect(capabilities.supportsExport == DynamoDBPlugin.supportsExport)
        #expect(capabilities.supportsSSH == DynamoDBPlugin.supportsSSH)
        #expect(capabilities.supportsSSL == DynamoDBPlugin.supportsSSL)
        #expect(capabilities.supportsReadOnlyMode == DynamoDBPlugin.supportsReadOnlyMode)
        #expect(capabilities.exactRowCountIsBilledScan)
    }

    @Test("Editor metadata matches the plugin")
    func editor() throws {
        let snapshot = try curated()
        let dialect = try #require(snapshot.editor.sqlDialect)
        let shipped = try #require(DynamoDBPlugin.sqlDialect)

        #expect(dialect.identifierQuote == shipped.identifierQuote)
        #expect(dialect.keywords == shipped.keywords)
        #expect(dialect.functions == shipped.functions)
        #expect(dialect.dataTypes == shipped.dataTypes)
        #expect(dialect.booleanLiteralStyle == shipped.booleanLiteralStyle)
        #expect(dialect.autoLimitStyle == shipped.autoLimitStyle)
        #expect(dialect.caseSensitivityStyle == shipped.caseSensitivityStyle)
        #expect(dialect.caseSensitivityStyle == .driverManaged)
        #expect(DynamoDBPlugin.caseSensitivityStyle == .driverManaged)
        #expect(snapshot.editor.columnTypesByCategory == DynamoDBPlugin.columnTypesByCategory)
        #expect(snapshot.editor.statementCompletions.map { [$0.label, $0.insertText] }
            == DynamoDBPlugin.statementCompletions.map { [$0.label, $0.insertText] })
    }

    @Test("Connection fields match the plugin")
    func connectionFields() throws {
        let fields = try curated().connection.additionalConnectionFields
        let shipped = DynamoDBConnectionFields.all

        #expect(fields.map(\.id) == shipped.map(\.id))
        #expect(fields.map(\.label) == shipped.map(\.label))
        #expect(fields.map(\.placeholder) == shipped.map(\.placeholder))
        #expect(fields.map(\.defaultValue) == shipped.map(\.defaultValue))
        #expect(fields.map(\.fieldType) == shipped.map(\.fieldType))
        #expect(fields.map(\.section) == shipped.map(\.section))
        #expect(fields.map(\.hidesPassword) == shipped.map(\.hidesPassword))
        #expect(fields.map(\.visibleWhen) == shipped.map(\.visibleWhen))
        #expect(fields.map(\.dynamicOptions) == shipped.map(\.dynamicOptions))
    }

    @Test("The region names no default, so a profile's own region is used")
    func regionHasNoDefault() throws {
        let region = try #require(try curated().connection.additionalConnectionFields.first { $0.id == "awsRegion" })

        #expect(region.defaultValue == nil)
    }

    @Test("DynamoDB Local is offered as a sign-in method")
    func localSignInIsOffered() throws {
        let method = try #require(try curated().connection.additionalConnectionFields.first { $0.id == "awsAuthMethod" })
        guard case .dropdown(let options) = method.fieldType else {
            Issue.record("The auth method is not a dropdown")
            return
        }

        #expect(options.map(\.value) == ["credentials", "profile", "sso", "local"])
    }
}
