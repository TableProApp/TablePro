//
//  DuckDBConnectionFieldsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("DuckDB connection fields")
struct DuckDBConnectionFieldsTests {
    private func duckdbFields() throws -> [ConnectionField] {
        let defaults = PluginMetadataRegistry.shared.registryPluginDefaults()
        let entry = try #require(defaults.first { $0.typeId == "DuckDB" })
        return entry.snapshot.connection.additionalConnectionFields
    }

    @Test("Registry declares mode, local, and remote fields in order")
    func registryDeclaresAllFields() throws {
        let fields = try duckdbFields()
        #expect(fields.map(\.id) == [
            "duckdbMode",
            "duckdbFilePath",
            "duckdbHost",
            "duckdbPort",
            "duckdbToken",
            "duckdbAlias"
        ])
    }

    @Test("Mode dropdown defaults to local and offers a remote option")
    func modeDropdownDefaultsToLocal() throws {
        let fields = try duckdbFields()
        let mode = try #require(fields.first { $0.id == "duckdbMode" })
        #expect(mode.defaultValue == "local")
        guard case .dropdown(let options) = mode.fieldType else {
            Issue.record("Expected a dropdown field type")
            return
        }
        #expect(options.map(\.value) == ["local", "remote"])
    }

    @Test("File path is required, visible only for local, and carries a Browse button")
    func filePathVisibleOnlyForLocal() throws {
        let fields = try duckdbFields()
        let path = try #require(fields.first { $0.id == "duckdbFilePath" })
        #expect(path.isRequired)
        #expect(path.fieldType == .text)
        #expect(path.visibleWhen == FieldVisibilityRule(fieldId: "duckdbMode", values: ["local"]))
        #expect(path.id.hasSuffix("FilePath"))
    }

    @Test("Host, port, token, and alias are visible only for remote")
    func remoteFieldsVisibleOnlyForRemote() throws {
        let fields = try duckdbFields()
        let remoteRule = FieldVisibilityRule(fieldId: "duckdbMode", values: ["remote"])
        for id in ["duckdbHost", "duckdbPort", "duckdbToken", "duckdbAlias"] {
            let field = try #require(fields.first { $0.id == id })
            #expect(field.visibleWhen == remoteRule)
        }
    }

    @Test("Token is a secure field that hides the main password row")
    func tokenIsSecureAndHidesPassword() throws {
        let fields = try duckdbFields()
        let token = try #require(fields.first { $0.id == "duckdbToken" })
        #expect(token.isSecure)
        #expect(token.hidesPassword)
    }

    @Test("Main password row stays hidden in both local and remote modes")
    func passwordAlwaysHidden() throws {
        let fields = try duckdbFields()
        #expect(fields.hidesPassword(forValues: [:]))
        #expect(fields.hidesPassword(forValues: ["duckdbMode": "local"]))
        #expect(fields.hidesPassword(forValues: ["duckdbMode": "remote"]))
    }

    @Test("Port defaults to 9494")
    func portDefaultsTo9494() throws {
        let fields = try duckdbFields()
        let port = try #require(fields.first { $0.id == "duckdbPort" })
        #expect(port.defaultValue == "9494")
    }

    @Test("Field visibility swaps between local and remote modes")
    @MainActor
    func visibilitySwapsByMode() throws {
        let type = DatabaseType(rawValue: "DuckDB")
        let fields = try duckdbFields()
        let path = try #require(fields.first { $0.id == "duckdbFilePath" })
        let host = try #require(fields.first { $0.id == "duckdbHost" })

        let local = ["duckdbMode": "local"]
        #expect(PluginFieldRendering.isFieldVisible(path, type: type, values: local))
        #expect(!PluginFieldRendering.isFieldVisible(host, type: type, values: local))

        let remote = ["duckdbMode": "remote"]
        #expect(!PluginFieldRendering.isFieldVisible(path, type: type, values: remote))
        #expect(PluginFieldRendering.isFieldVisible(host, type: type, values: remote))
    }
}
