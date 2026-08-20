//
//  PluginModelsTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("PluginEntry Computed Properties")
struct PluginEntryTests {

    private func makeEntry(
        databaseTypeId: String? = nil,
        additionalTypeIds: [String] = [],
        pluginIconName: String = "puzzlepiece",
        defaultPort: Int? = nil
    ) -> PluginEntry {
        PluginEntry(
            id: "test.plugin",
            bundle: Bundle.main,
            url: Bundle.main.bundleURL,
            source: .builtIn,
            name: "Test Plugin",
            version: "1.0.0",
            pluginDescription: "A test plugin",
            capabilities: [.databaseDriver],
            isEnabled: true,
            databaseTypeId: databaseTypeId,
            additionalTypeIds: additionalTypeIds,
            pluginIconName: pluginIconName,
            defaultPort: defaultPort,
            exportFormatId: nil,
            importFormatId: nil,
            inspectorId: nil
        )
    }

    @Test("databaseTypeId returns nil when not set")
    func databaseTypeIdNil() {
        let entry = makeEntry()
        #expect(entry.databaseTypeId == nil)
    }

    @Test("databaseTypeId returns value when set")
    func databaseTypeIdSet() {
        let entry = makeEntry(databaseTypeId: "MySQL")
        #expect(entry.databaseTypeId == "MySQL")
    }

    @Test("additionalTypeIds returns empty array by default")
    func additionalTypeIdsEmpty() {
        let entry = makeEntry()
        #expect(entry.additionalTypeIds.isEmpty)
    }

    @Test("defaultPort returns nil when not set")
    func defaultPortNil() {
        let entry = makeEntry()
        #expect(entry.defaultPort == nil)
    }

    @Test("pluginIconName returns provided value")
    func pluginIconName() {
        let entry = makeEntry(pluginIconName: "mysql-icon")
        #expect(entry.pluginIconName == "mysql-icon")
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
            isEnabled: false,
            databaseTypeId: nil,
            additionalTypeIds: [],
            pluginIconName: "puzzlepiece",
            defaultPort: nil,
            exportFormatId: nil,
            importFormatId: nil,
            inspectorId: nil
        )
        #expect(entry.id == "com.example.test-plugin")
    }
}
