//
//  LibSQLConnectionFieldsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("libSQL connection fields")
struct LibSQLConnectionFieldsTests {
    private func libsqlFields() throws -> [ConnectionField] {
        let defaults = PluginMetadataRegistry.shared.registryPluginDefaults()
        let entry = try #require(defaults.first { $0.typeId == "libSQL" })
        return entry.snapshot.connection.additionalConnectionFields
    }

    @Test("Registry entry declares mode, URL, and file path fields")
    func registryDeclaresAllFields() throws {
        let fields = try libsqlFields()
        #expect(fields.map(\.id) == ["libsqlMode", "databaseUrl", "libsqlFilePath"])
    }

    @Test("Mode dropdown defaults to remote and offers a local option")
    func modeDropdownDefaultsToRemote() throws {
        let fields = try libsqlFields()
        let mode = try #require(fields.first { $0.id == "libsqlMode" })
        #expect(mode.defaultValue == "remote")
        guard case .dropdown(let options) = mode.fieldType else {
            Issue.record("Expected a dropdown field type")
            return
        }
        #expect(options.map(\.value) == ["remote", "local"])
    }

    @Test("Database URL is required and visible only in remote mode")
    func databaseUrlVisibleOnlyForRemote() throws {
        let fields = try libsqlFields()
        let url = try #require(fields.first { $0.id == "databaseUrl" })
        #expect(url.isRequired)
        #expect(url.visibleWhen == FieldVisibilityRule(fieldId: "libsqlMode", values: ["remote"]))
    }

    @Test("File path is a required text field visible only in local mode")
    func filePathVisibleOnlyForLocal() throws {
        let fields = try libsqlFields()
        let path = try #require(fields.first { $0.id == "libsqlFilePath" })
        #expect(path.isRequired)
        #expect(path.fieldType == .text)
        #expect(path.visibleWhen == FieldVisibilityRule(fieldId: "libsqlMode", values: ["local"]))
    }

    @Test("Password row stays for remote mode and hides for local mode")
    func passwordHidingFollowsMode() throws {
        let fields = try libsqlFields()
        #expect(!fields.hidesPassword(forValues: [:]))
        #expect(!fields.hidesPassword(forValues: ["libsqlMode": "remote"]))
        #expect(fields.hidesPassword(forValues: ["libsqlMode": "local"]))
    }

    @Test("Saved connections without a mode value resolve to remote visibility")
    @MainActor
    func missingModeValueShowsRemoteFields() throws {
        let type = DatabaseType(rawValue: "libSQL")
        let fields = try libsqlFields()
        let url = try #require(fields.first { $0.id == "databaseUrl" })
        let path = try #require(fields.first { $0.id == "libsqlFilePath" })
        #expect(PluginFieldRendering.isFieldVisible(url, type: type, values: [:]))
        #expect(!PluginFieldRendering.isFieldVisible(path, type: type, values: [:]))
    }

    @Test("Local mode swaps field visibility")
    @MainActor
    func localModeSwapsVisibility() throws {
        let type = DatabaseType(rawValue: "libSQL")
        let fields = try libsqlFields()
        let url = try #require(fields.first { $0.id == "databaseUrl" })
        let path = try #require(fields.first { $0.id == "libsqlFilePath" })
        let values = ["libsqlMode": "local"]
        #expect(!PluginFieldRendering.isFieldVisible(url, type: type, values: values))
        #expect(PluginFieldRendering.isFieldVisible(path, type: type, values: values))
    }

    @Test("libSQL claims no file extensions so SQLite keeps file-open routing")
    func noFileExtensionClaim() throws {
        let defaults = PluginMetadataRegistry.shared.registryPluginDefaults()
        let entry = try #require(defaults.first { $0.typeId == "libSQL" })
        #expect(entry.snapshot.schema.fileExtensions.isEmpty)
    }
}
