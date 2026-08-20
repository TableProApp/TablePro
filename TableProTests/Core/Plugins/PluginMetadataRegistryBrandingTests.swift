//
//  PluginMetadataRegistryBrandingTests.swift
//  TableProTests
//
//  Locks in the fix that withBranding preserves only visual identity
//  (displayName, iconName, brandColorHex), not the entire connection config.
//  Regression guard for: a plugin's freshly declared additionalConnectionFields
//  must not be clobbered by the existing registry default's connection block
//  during register(..., preserveIcon: true).
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
@Suite("PluginMetadataSnapshot branding preservation")
struct PluginMetadataRegistryBrandingTests {
    private static let pluginField = ConnectionField(
        id: "newPluginField",
        label: "New Plugin Field",
        defaultValue: "x",
        section: .connection
    )

    private static let existingField = ConnectionField(
        id: "oldDefaultField",
        label: "Old Default Field",
        defaultValue: "y",
        section: .connection
    )

    private static func snapshot(
        displayName: String,
        iconName: String,
        brandColorHex: String,
        defaultPort: Int,
        fields: [ConnectionField]
    ) -> PluginMetadataSnapshot {
        PluginMetadataSnapshot(
            displayName: displayName, iconName: iconName, defaultPort: defaultPort,
            requiresAuthentication: false, supportsForeignKeys: false, supportsSchemaEditing: false,
            isDownloadable: false, primaryUrlScheme: "brandtest", parameterStyle: .questionMark,
            navigationModel: .inPlace, explainVariants: [], pathFieldRole: .database,
            supportsHealthMonitor: false, urlSchemes: ["brandtest"], postConnectActions: [],
            brandColorHex: brandColorHex, queryLanguageName: "Q", editorLanguage: .bash,
            connectionMode: .network, supportsDatabaseSwitching: false,
            supportsColumnReorder: false,
            capabilities: .defaults, schema: .defaults, editor: .defaults,
            connection: PluginMetadataSnapshot.ConnectionConfig(
                additionalConnectionFields: fields,
                category: .other,
                tagline: ""
            )
        )
    }

    @Test("withBranding takes branding from source but keeps self's connection config")
    func withBrandingKeepsSelfConnection() {
        let plugin = Self.snapshot(
            displayName: "PluginName",
            iconName: "plugin-icon",
            brandColorHex: "#111111",
            defaultPort: 7_000,
            fields: [Self.pluginField]
        )
        let existing = Self.snapshot(
            displayName: "ExistingName",
            iconName: "existing-icon",
            brandColorHex: "#999999",
            defaultPort: 8_000,
            fields: [Self.existingField]
        )

        let merged = plugin.withBranding(from: existing)

        #expect(merged.displayName == "ExistingName")
        #expect(merged.iconName == "existing-icon")
        #expect(merged.brandColorHex == "#999999")

        let mergedIds = merged.connection.additionalConnectionFields.map(\.id)
        #expect(mergedIds == ["newPluginField"])

        #expect(merged.defaultPort == 7_000)
    }

    @Test("register with preserveIcon keeps the plugin's new fields")
    func registerPreserveIconKeepsPluginFields() {
        let registry = PluginMetadataRegistry.shared
        let typeId = "BrandTestPluginType"

        guard registry.snapshot(forTypeId: typeId) == nil else {
            Issue.record("Test type \(typeId) unexpectedly in registry defaults")
            return
        }

        let existing = Self.snapshot(
            displayName: "BrandTest",
            iconName: "existing-icon",
            brandColorHex: "#111111",
            defaultPort: 7_000,
            fields: [Self.existingField]
        )
        registry.register(snapshot: existing, forTypeId: typeId)

        let pluginSnapshot = Self.snapshot(
            displayName: "WrongName",
            iconName: "wrong-icon",
            brandColorHex: "#222222",
            defaultPort: 7_000,
            fields: [Self.pluginField]
        )
        registry.register(snapshot: pluginSnapshot, forTypeId: typeId, preserveIcon: true)

        let resolved = registry.snapshot(forTypeId: typeId)
        #expect(resolved?.iconName == "existing-icon")
        #expect(resolved?.displayName == "BrandTest")
        #expect(resolved?.connection.additionalConnectionFields.map(\.id) == ["newPluginField"])

        registry.unregister(typeId: typeId)
    }
}
