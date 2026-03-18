//
//  PluginModelsTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("PluginEntry Computed Properties — Fallback Behavior")
struct PluginEntryFallbackTests {

    private func makeNonPluginEntry() -> PluginEntry {
        PluginEntry(
            id: "test.non-plugin",
            bundle: Bundle.main,
            url: Bundle.main.bundleURL,
            source: .builtIn,
            name: "Non-Plugin Bundle",
            version: "1.0.0",
            pluginDescription: "A bundle whose principalClass is not a DriverPlugin",
            capabilities: [.databaseDriver],
            isEnabled: true
        )
    }

    @Test("driverPlugin returns nil for a non-plugin bundle")
    func driverPluginReturnsNil() {
        let entry = makeNonPluginEntry()
        #expect(entry.driverPlugin == nil)
    }

    @Test("iconName falls back to puzzlepiece when driverPlugin is nil")
    func iconNameFallback() {
        let entry = makeNonPluginEntry()
        #expect(entry.iconName == "puzzlepiece")
    }

    @Test("databaseTypeId returns nil when driverPlugin is nil")
    func databaseTypeIdNil() {
        let entry = makeNonPluginEntry()
        #expect(entry.databaseTypeId == nil)
    }

    @Test("additionalTypeIds returns empty array when driverPlugin is nil")
    func additionalTypeIdsEmpty() {
        let entry = makeNonPluginEntry()
        #expect(entry.additionalTypeIds.isEmpty)
    }

    @Test("defaultPort returns nil when driverPlugin is nil")
    func defaultPortNil() {
        let entry = makeNonPluginEntry()
        #expect(entry.defaultPort == nil)
    }
}

@Suite("PluginSource Enum")
struct PluginSourceTests {

    @Test("PluginSource has builtIn and userInstalled cases")
    func pluginSourceCases() {
        let builtIn = PluginSource.builtIn
        let userInstalled = PluginSource.userInstalled

        #expect(builtIn != userInstalled)
    }
}

@Suite("PluginEntry Identity")
struct PluginEntryIdentityTests {

    @Test("id property serves as the Identifiable conformance")
    func identifiable() {
        let entry = PluginEntry(
            id: "com.example.test-plugin",
            bundle: Bundle.main,
            url: Bundle.main.bundleURL,
            source: .userInstalled,
            name: "Test",
            version: "0.1.0",
            pluginDescription: "",
            capabilities: [],
            isEnabled: false
        )
        #expect(entry.id == "com.example.test-plugin")
    }
}
