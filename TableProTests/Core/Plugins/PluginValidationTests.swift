//
//  PluginValidationTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

// MARK: - Mock DriverPlugin for Testing

private final class MockDriverPlugin: NSObject, TableProPlugin, DriverPlugin {
    static var pluginName = "MockDriver"
    static var pluginVersion = "1.0.0"
    static var pluginDescription = "Test plugin"
    static var capabilities: [PluginCapability] = [.databaseDriver]
    static var dependencies: [String] = []

    static var databaseTypeId = "mock-db"
    static var databaseDisplayName = "Mock Database"
    static var iconName = "cylinder.fill"
    static var defaultPort = 9999

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }

    required override init() {
        super.init()
    }

    static func reset(
        typeId: String = "mock-db",
        displayName: String = "Mock Database",
        additionalIds: [String] = []
    ) {
        databaseTypeId = typeId
        databaseDisplayName = displayName
        additionalDatabaseTypeIds = additionalIds
    }

    static var additionalDatabaseTypeIds: [String] = []
}

// MARK: - validateDriverDescriptor Tests

@Suite("PluginManager.validateDriverDescriptor", .serialized)
struct ValidateDriverDescriptorTests {

    @Test("rejects empty databaseTypeId")
    @MainActor func rejectsEmptyTypeId() {
        MockDriverPlugin.reset(typeId: "")
        let pm = PluginManager.shared
        #expect(throws: PluginError.self) {
            try pm.validateDriverDescriptor(MockDriverPlugin.self, pluginId: "test")
        }
    }

    @Test("rejects whitespace-only databaseTypeId")
    @MainActor func rejectsWhitespaceTypeId() {
        MockDriverPlugin.reset(typeId: "   ")
        let pm = PluginManager.shared
        #expect(throws: PluginError.self) {
            try pm.validateDriverDescriptor(MockDriverPlugin.self, pluginId: "test")
        }
    }

    @Test("rejects empty databaseDisplayName")
    @MainActor func rejectsEmptyDisplayName() {
        MockDriverPlugin.reset(typeId: "valid-id", displayName: "")
        let pm = PluginManager.shared
        #expect(throws: PluginError.self) {
            try pm.validateDriverDescriptor(MockDriverPlugin.self, pluginId: "test")
        }
    }

    @Test("rejects whitespace-only databaseDisplayName")
    @MainActor func rejectsWhitespaceDisplayName() {
        MockDriverPlugin.reset(typeId: "valid-id", displayName: "   ")
        let pm = PluginManager.shared
        #expect(throws: PluginError.self) {
            try pm.validateDriverDescriptor(MockDriverPlugin.self, pluginId: "test")
        }
    }

    @Test("accepts valid descriptor with no conflicts")
    @MainActor func acceptsValidDescriptor() throws {
        MockDriverPlugin.reset(typeId: "unique-test-db-type", displayName: "Unique Test DB")
        let pm = PluginManager.shared
        try pm.validateDriverDescriptor(MockDriverPlugin.self, pluginId: "test")
    }

    @Test("rejects duplicate primary type ID already registered")
    @MainActor func rejectsDuplicatePrimaryTypeId() {
        // "MySQL" is registered by the built-in MySQL plugin
        MockDriverPlugin.reset(typeId: "MySQL", displayName: "Fake MySQL")
        let pm = PluginManager.shared
        #expect(throws: PluginError.self) {
            try pm.validateDriverDescriptor(MockDriverPlugin.self, pluginId: "test")
        }
    }

    @Test("rejects duplicate additional type ID already registered")
    @MainActor func rejectsDuplicateAdditionalTypeId() {
        MockDriverPlugin.reset(
            typeId: "unique-test-db-type-2",
            displayName: "Test DB",
            additionalIds: ["MySQL"]
        )
        let pm = PluginManager.shared
        #expect(throws: PluginError.self) {
            try pm.validateDriverDescriptor(MockDriverPlugin.self, pluginId: "test")
        }
    }
}

// MARK: - PluginError.invalidDescriptor Formatting

@Suite("PluginError.invalidDescriptor")
struct PluginErrorInvalidDescriptorTests {

    @Test("error description includes plugin ID and reason")
    func errorDescription() {
        let error = PluginError.invalidDescriptor(
            pluginId: "com.example.broken",
            reason: "databaseTypeId is empty"
        )
        let description = error.localizedDescription
        #expect(description.contains("com.example.broken"))
        #expect(description.contains("databaseTypeId is empty"))
    }

    @Test("error description for duplicate type ID includes existing plugin name")
    func duplicateTypeIdDescription() {
        let error = PluginError.invalidDescriptor(
            pluginId: "com.example.new-plugin",
            reason: "databaseTypeId 'mysql' is already registered by 'MySQL'"
        )
        let description = error.localizedDescription
        #expect(description.contains("com.example.new-plugin"))
        #expect(description.contains("mysql"))
        #expect(description.contains("MySQL"))
    }
}

// MARK: - validateConnectionFields Tests

@Suite("PluginManager.validateConnectionFields")
struct ValidateConnectionFieldsTests {

    @Test("duplicate field IDs are detected")
    @MainActor func duplicateFieldIds() {
        let fields = [
            ConnectionField(id: "encoding", label: "Encoding"),
            ConnectionField(id: "timeout", label: "Timeout"),
            ConnectionField(id: "encoding", label: "Character Encoding")
        ]
        // Should not crash — warns via logger
        PluginManager.shared.validateConnectionFields(fields, pluginId: "test")
    }

    @Test("empty field ID is detected without crash")
    @MainActor func emptyFieldId() {
        let fields = [ConnectionField(id: "", label: "Something")]
        PluginManager.shared.validateConnectionFields(fields, pluginId: "test")
    }

    @Test("empty field label is detected without crash")
    @MainActor func emptyFieldLabel() {
        let fields = [ConnectionField(id: "test", label: "")]
        PluginManager.shared.validateConnectionFields(fields, pluginId: "test")
    }

    @Test("dropdown with empty options is detected without crash")
    @MainActor func emptyDropdownOptions() {
        let fields = [
            ConnectionField(
                id: "encoding",
                label: "Encoding",
                fieldType: .dropdown(options: [])
            )
        ]
        PluginManager.shared.validateConnectionFields(fields, pluginId: "test")
    }

    @Test("valid fields pass without issue")
    @MainActor func validFields() {
        let fields = [
            ConnectionField(id: "encoding", label: "Encoding"),
            ConnectionField(
                id: "mode",
                label: "Mode",
                fieldType: .dropdown(options: [
                    ConnectionField.DropdownOption(value: "fast", label: "Fast"),
                    ConnectionField.DropdownOption(value: "safe", label: "Safe")
                ])
            )
        ]
        PluginManager.shared.validateConnectionFields(fields, pluginId: "test")
    }
}
