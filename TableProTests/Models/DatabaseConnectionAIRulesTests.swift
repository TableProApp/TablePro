//
//  DatabaseConnectionAIRulesTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("DatabaseConnection.aiRules")
struct DatabaseConnectionAIRulesTests {
    @Test("aiRules defaults to nil")
    func defaultsToNil() {
        let conn = TestFixtures.makeConnection()
        #expect(conn.aiRules == nil)
    }

    @Test("init populates aiRules")
    func initPopulatesAIRules() {
        let conn = DatabaseConnection(
            name: "Test",
            type: .mysql,
            aiRules: "Always filter by tenant_id."
        )
        #expect(conn.aiRules == "Always filter by tenant_id.")
    }

    @Test("aiRules is mutable on var")
    func aiRulesMutable() {
        var conn = TestFixtures.makeConnection()
        conn.aiRules = "Avoid users.ssn"
        #expect(conn.aiRules == "Avoid users.ssn")
    }

    @Test("Codable round-trip preserves aiRules")
    func codableRoundTripWithRules() throws {
        let original = DatabaseConnection(
            name: "Prod",
            type: .postgresql,
            aiRules: "- Tables prefixed with `tmp_` are scratch.\n- Never select users.ssn."
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(decoded.aiRules == original.aiRules)
    }

    @Test("Codable round-trip preserves nil aiRules")
    func codableRoundTripNilRules() throws {
        let original = TestFixtures.makeConnection()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(decoded.aiRules == nil)
    }

    @Test("Decode without aiRules key produces nil for forward compatibility")
    func decodeLegacyJSONWithoutAIRulesKey() throws {
        let id = UUID()
        let legacyJSON = """
        {
            "id": "\(id.uuidString)",
            "name": "Legacy",
            "type": "MySQL"
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(decoded.aiRules == nil)
        #expect(decoded.name == "Legacy")
    }

    @Test("Empty aiRules string round-trips as empty string")
    func emptyStringRoundTrip() throws {
        let original = DatabaseConnection(
            name: "Empty",
            type: .mysql,
            aiRules: ""
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(decoded.aiRules == "")
    }

    @Test("System prompt includes connection rules section when rules are non-empty")
    func systemPromptIncludesRulesSection() {
        let prompt = AISchemaContext.buildSystemPrompt(
            databaseType: .postgresql,
            databaseName: "shop",
            tables: [],
            columnsByTable: [:],
            foreignKeys: [:],
            currentQuery: nil,
            queryResults: nil,
            settings: AISettings.default,
            editorLanguage: .sql,
            queryLanguageName: "SQL",
            connectionRules: "Filter orders by deleted_at IS NULL."
        )
        #expect(prompt.contains("## Connection-Specific Rules"))
        #expect(prompt.contains("Filter orders by deleted_at IS NULL."))
    }

    @Test("System prompt omits connection rules section when nil")
    func systemPromptOmitsRulesWhenNil() {
        let prompt = AISchemaContext.buildSystemPrompt(
            databaseType: .postgresql,
            databaseName: "shop",
            tables: [],
            columnsByTable: [:],
            foreignKeys: [:],
            currentQuery: nil,
            queryResults: nil,
            settings: AISettings.default,
            editorLanguage: .sql,
            queryLanguageName: "SQL",
            connectionRules: nil
        )
        #expect(!prompt.contains("## Connection-Specific Rules"))
    }

    @Test("System prompt omits connection rules section when whitespace only")
    func systemPromptOmitsRulesWhenWhitespace() {
        let prompt = AISchemaContext.buildSystemPrompt(
            databaseType: .postgresql,
            databaseName: "shop",
            tables: [],
            columnsByTable: [:],
            foreignKeys: [:],
            currentQuery: nil,
            queryResults: nil,
            settings: AISettings.default,
            editorLanguage: .sql,
            queryLanguageName: "SQL",
            connectionRules: "  \n\t  "
        )
        #expect(!prompt.contains("## Connection-Specific Rules"))
    }
}
