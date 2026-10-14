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
    static let pluginName = "MockDriver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Test plugin"
    static let capabilities: [PluginCapability] = [.databaseDriver]
    static let dependencies: [String] = []

    nonisolated(unsafe) static var databaseTypeId = "mock-db"
    nonisolated(unsafe) static var databaseDisplayName = "Mock Database"
    static let iconName = "cylinder.fill"
    static let defaultPort = 9999

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

    nonisolated(unsafe) static var additionalDatabaseTypeIds: [String] = []
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
    /// The collision is set up here rather than assumed. `driverPlugins` is filled when a plugin
    /// loads, and discovery ends with "will load on first use", so nothing had put MySQL in the
    /// table and the duplicate check had nothing to collide with. Calling `loadPlugins()` does not
    /// fill it either: the bundles do not register in the xctest host.
    @MainActor func rejectsDuplicatePrimaryTypeId() {
        let pm = PluginManager.shared
        MockDriverPlugin.reset(typeId: "occupied-primary-id", displayName: "Occupant")
        let occupant = MockDriverPlugin()
        pm.driverPlugins["occupied-primary-id"] = occupant
        defer { pm.driverPlugins.removeValue(forKey: "occupied-primary-id") }

        MockDriverPlugin.reset(typeId: "occupied-primary-id", displayName: "Fake Occupant")
        #expect(throws: PluginError.self) {
            try pm.validateDriverDescriptor(MockDriverPlugin.self, pluginId: "test")
        }
    }

    @Test("rejects duplicate additional type ID already registered")
    @MainActor func rejectsDuplicateAdditionalTypeId() {
        let pm = PluginManager.shared
        MockDriverPlugin.reset(typeId: "occupied-additional-id", displayName: "Occupant")
        let occupant = MockDriverPlugin()
        pm.driverPlugins["occupied-additional-id"] = occupant
        defer { pm.driverPlugins.removeValue(forKey: "occupied-additional-id") }

        MockDriverPlugin.reset(
            typeId: "unique-test-db-type-2",
            displayName: "Test DB",
            additionalIds: ["occupied-additional-id"]
        )
        #expect(throws: PluginError.self) {
            try pm.validateDriverDescriptor(MockDriverPlugin.self, pluginId: "test")
        }
    }
}

// MARK: - PluginError.invalidDescriptor Formatting

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
