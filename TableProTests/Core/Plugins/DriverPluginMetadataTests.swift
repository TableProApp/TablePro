//
//  DriverPluginMetadataTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

// MARK: - Mock Plugin for Default Verification

private final class MockDefaultPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock Default"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Plugin with all defaults"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "MockDB"
    static let databaseDisplayName = "Mock Database"
    static let iconName = "cylinder.fill"
    static let defaultPort = 9999

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

// MARK: - Mock Plugin with Custom Overrides

private final class MockCustomPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock Custom"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Plugin with custom values"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "CustomDB"
    static let databaseDisplayName = "Custom Database"
    static let iconName = "doc.fill"
    static let defaultPort = 0

    static let requiresAuthentication = false
    static let connectionMode: ConnectionMode = .fileBased
    static let urlSchemes: [String] = ["customdb"]
    static let fileExtensions: [String] = ["cdb", "customdb"]
    static let brandColorHex = "#FF0000"
    static let queryLanguageName = "CQL"
    static let editorLanguage: EditorLanguage = .custom("cypher")
    static let supportsForeignKeys = false
    static let supportsSchemaEditing = false
    static let supportsDatabaseSwitching = false
    static let supportsImport = false
    static let supportsExport = false
    static let databaseGroupingStrategy: GroupingStrategy = .flat
    static let defaultGroupName = "default"
    static let systemDatabaseNames: [String] = ["system", "internal"]
    static let columnTypesByCategory: [String: [String]] = [
        "String": ["text"],
        "Number": ["integer"],
        "Binary": []
    ]

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

// MARK: - ConnectionMode Tests

@Suite("ConnectionMode Enum")
struct ConnectionModeTests {
    @Test("Raw values match expected strings")
    func rawValues() {
        #expect(ConnectionMode.network.rawValue == "network")
        #expect(ConnectionMode.fileBased.rawValue == "fileBased")
    }

    @Test("Codable round-trip")
    func codable() throws {
        for mode in [ConnectionMode.network, .fileBased] {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(ConnectionMode.self, from: data)
            #expect(decoded == mode)
        }
    }
}

// MARK: - EditorLanguage Tests

@Suite("EditorLanguage Enum")
struct EditorLanguageTests {
    @Test("Equatable for known cases")
    func equatable() {
        #expect(EditorLanguage.sql == EditorLanguage.sql)
        #expect(EditorLanguage.javascript == EditorLanguage.javascript)
        #expect(EditorLanguage.bash == EditorLanguage.bash)
        #expect(EditorLanguage.sql != EditorLanguage.javascript)
    }

    @Test("Custom case with associated value")
    func customCase() {
        let lang = EditorLanguage.custom("graphql")
        #expect(lang == EditorLanguage.custom("graphql"))
        #expect(lang != EditorLanguage.custom("cypher"))
        #expect(lang != EditorLanguage.sql)
    }

    @Test("Codable round-trip for all cases")
    func codable() throws {
        let cases: [EditorLanguage] = [.sql, .javascript, .bash, .custom("graphql")]
        for lang in cases {
            let data = try JSONEncoder().encode(lang)
            let decoded = try JSONDecoder().decode(EditorLanguage.self, from: data)
            #expect(decoded == lang)
        }
    }
}

// MARK: - GroupingStrategy Tests

@Suite("GroupingStrategy Enum")
struct GroupingStrategyTests {
    @Test("Raw values match expected strings")
    func rawValues() {
        #expect(GroupingStrategy.byDatabase.rawValue == "byDatabase")
        #expect(GroupingStrategy.bySchema.rawValue == "bySchema")
        #expect(GroupingStrategy.flat.rawValue == "flat")
    }

    @Test("Codable round-trip")
    func codable() throws {
        for strategy in [GroupingStrategy.byDatabase, .bySchema, .flat] {
            let data = try JSONEncoder().encode(strategy)
            let decoded = try JSONDecoder().decode(GroupingStrategy.self, from: data)
            #expect(decoded == strategy)
        }
    }
}

// MARK: - DriverPlugin Protocol Defaults

@Suite("DriverPlugin Protocol Defaults")
struct DriverPluginDefaultsTests {
    @Test("Default requiresAuthentication is true")
    func requiresAuthentication() {
        #expect(MockDefaultPlugin.requiresAuthentication == true)
    }

    @Test("Default connectionMode is .network")
    func connectionMode() {
        #expect(MockDefaultPlugin.connectionMode == .network)
    }

    @Test("Default urlSchemes is empty")
    func urlSchemes() {
        #expect(MockDefaultPlugin.urlSchemes.isEmpty)
    }

    @Test("Default fileExtensions is empty")
    func fileExtensions() {
        #expect(MockDefaultPlugin.fileExtensions.isEmpty)
    }

    @Test("Default brandColorHex is gray")
    func brandColorHex() {
        #expect(MockDefaultPlugin.brandColorHex == "#808080")
    }

    @Test("Default queryLanguageName is SQL")
    func queryLanguageName() {
        #expect(MockDefaultPlugin.queryLanguageName == "SQL")
    }

    @Test("Default editorLanguage is .sql")
    func editorLanguage() {
        #expect(MockDefaultPlugin.editorLanguage == .sql)
    }

    @Test("Default supportsForeignKeys is true")
    func supportsForeignKeys() {
        #expect(MockDefaultPlugin.supportsForeignKeys == true)
    }

    @Test("Default supportsSchemaEditing is true")
    func supportsSchemaEditing() {
        #expect(MockDefaultPlugin.supportsSchemaEditing == true)
    }

    @Test("Default supportsDatabaseSwitching is true")
    func supportsDatabaseSwitching() {
        #expect(MockDefaultPlugin.supportsDatabaseSwitching == true)
    }

    @Test("Default supportsSchemaSwitching is false")
    func supportsSchemaSwitching() {
        #expect(MockDefaultPlugin.supportsSchemaSwitching == false)
    }

    @Test("Default supportsImport is true")
    func supportsImport() {
        #expect(MockDefaultPlugin.supportsImport == true)
    }

    @Test("Default supportsExport is true")
    func supportsExport() {
        #expect(MockDefaultPlugin.supportsExport == true)
    }

    @Test("Default supportsHealthMonitor is true")
    func supportsHealthMonitor() {
        #expect(MockDefaultPlugin.supportsHealthMonitor == true)
    }

    @Test("Default systemDatabaseNames is empty")
    func systemDatabaseNames() {
        #expect(MockDefaultPlugin.systemDatabaseNames.isEmpty)
    }

    @Test("Default systemSchemaNames is empty")
    func systemSchemaNames() {
        #expect(MockDefaultPlugin.systemSchemaNames.isEmpty)
    }

    @Test("Default databaseGroupingStrategy is .byDatabase")
    func databaseGroupingStrategy() {
        #expect(MockDefaultPlugin.databaseGroupingStrategy == .byDatabase)
    }

    @Test("Default defaultGroupName is main")
    func defaultGroupName() {
        #expect(MockDefaultPlugin.defaultGroupName == "main")
    }

    @Test("Default columnTypesByCategory contains standard SQL categories")
    func columnTypesByCategory() {
        let types = MockDefaultPlugin.columnTypesByCategory
        #expect(types["Integer"] != nil)
        #expect(types["Float"] != nil)
        #expect(types["String"] != nil)
        #expect(types["Date"] != nil)
        #expect(types["Binary"] != nil)
        #expect(types["Boolean"] != nil)
        #expect(types["JSON"] != nil)
    }
}

// MARK: - Custom Override Verification

@Suite("DriverPlugin Custom Overrides")
struct DriverPluginCustomOverridesTests {
    @Test("Custom plugin overrides all defaults correctly")
    func customOverrides() {
        #expect(MockCustomPlugin.requiresAuthentication == false)
        #expect(MockCustomPlugin.connectionMode == .fileBased)
        #expect(MockCustomPlugin.urlSchemes == ["customdb"])
        #expect(MockCustomPlugin.fileExtensions == ["cdb", "customdb"])
        #expect(MockCustomPlugin.brandColorHex == "#FF0000")
        #expect(MockCustomPlugin.queryLanguageName == "CQL")
        #expect(MockCustomPlugin.editorLanguage == .custom("cypher"))
        #expect(MockCustomPlugin.supportsForeignKeys == false)
        #expect(MockCustomPlugin.supportsSchemaEditing == false)
        #expect(MockCustomPlugin.supportsDatabaseSwitching == false)
        #expect(MockCustomPlugin.supportsImport == false)
        #expect(MockCustomPlugin.supportsExport == false)
        #expect(MockCustomPlugin.databaseGroupingStrategy == .flat)
        #expect(MockCustomPlugin.defaultGroupName == "default")
        #expect(MockCustomPlugin.systemDatabaseNames == ["system", "internal"])
    }

    @Test("Empty arrays in columnTypesByCategory are preserved")
    func emptyArraysPreserved() {
        let types = MockCustomPlugin.columnTypesByCategory
        #expect(types["Binary"] == [])
        #expect(types["String"] == ["text"])
        #expect(types["Number"] == ["integer"])
    }

    @Test("Non-overridden values still use defaults")
    func nonOverriddenDefaults() {
        #expect(MockCustomPlugin.supportsSchemaSwitching == false)
        #expect(MockCustomPlugin.supportsHealthMonitor == true)
        #expect(MockCustomPlugin.systemSchemaNames.isEmpty)
    }
}

// NOTE: Per-plugin metadata tests (MySQL, PostgreSQL, etc.) cannot run in xcodebuild test
// because .tableplugin bundles are loaded at runtime by the main app, not the test runner.
// The protocol defaults and override mechanism are fully covered by the mock-based tests above.
