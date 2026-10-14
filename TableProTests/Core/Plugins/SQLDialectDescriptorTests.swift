//
//  SQLDialectDescriptorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct SQLDialectDescriptorTests {
    // MARK: - SQLDialectDescriptor Creation

    @Test
    func descriptorCreation() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "`",
            keywords: ["SELECT", "FROM", "WHERE"],
            functions: ["COUNT", "SUM"],
            dataTypes: ["INT", "VARCHAR"]
        )

        #expect(descriptor.identifierQuote == "`")
        #expect(descriptor.keywords == ["SELECT", "FROM", "WHERE"])
        #expect(descriptor.functions == ["COUNT", "SUM"])
        #expect(descriptor.dataTypes == ["INT", "VARCHAR"])
    }

    @Test
    func descriptorWithEmptySets() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [],
            functions: [],
            dataTypes: []
        )

        #expect(descriptor.identifierQuote == "\"")
        #expect(descriptor.keywords.isEmpty)
        #expect(descriptor.functions.isEmpty)
        #expect(descriptor.dataTypes.isEmpty)
    }

    // MARK: - PluginDialectAdapter

    @MainActor
    @Test
    func pluginDialectAdapterWrapsDescriptor() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "[",
            keywords: ["SELECT", "TOP", "NOLOCK"],
            functions: ["LEN", "GETDATE"],
            dataTypes: ["NVARCHAR", "BIT"]
        )

        let adapter = PluginDialectAdapter(descriptor: descriptor)

        #expect(adapter.identifierQuote == "[")
        #expect(adapter.keywords == ["SELECT", "TOP", "NOLOCK"])
        #expect(adapter.functions == ["LEN", "GETDATE"])
        #expect(adapter.dataTypes == ["NVARCHAR", "BIT"])
    }

    @MainActor
    @Test
    func pluginDialectAdapterConformsToSQLDialectProvider() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "`",
            keywords: ["SELECT", "FROM"],
            functions: ["COUNT", "SUM"],
            dataTypes: ["INT", "TEXT"]
        )

        let adapter: SQLDialectProvider = PluginDialectAdapter(descriptor: descriptor)

        #expect(adapter.isKeyword("SELECT"))
        #expect(adapter.isKeyword("select"))
        #expect(!adapter.isKeyword("NONEXISTENT"))

        #expect(adapter.isFunction("COUNT"))
        #expect(adapter.isFunction("count"))
        #expect(!adapter.isFunction("NONEXISTENT"))

        #expect(adapter.isDataType("INT"))
        #expect(adapter.isDataType("int"))
        #expect(!adapter.isDataType("NONEXISTENT"))
    }

    @Test
    func textCastTypeNameDefaultsToNil() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "`", keywords: [], functions: [], dataTypes: []
        )
        #expect(descriptor.textCastTypeName == nil)
    }

    @Test
    func textCastTypeNameSurvivesCaseSensitivityRestyle() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
            caseSensitivityStyle: .ilikeOperator, textCastTypeName: "TEXT"
        )
        let restyled = descriptor.withCaseSensitivityStyle(.caseFoldFunction)
        #expect(descriptor.textCastTypeName == "TEXT")
        #expect(restyled.textCastTypeName == "TEXT")
        #expect(restyled.caseSensitivityStyle == .caseFoldFunction)
    }
}
