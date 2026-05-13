//
//  CustomSlashCommandRendererTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("CustomSlashCommandRenderer")
struct CustomSlashCommandRendererTests {
    private func makeCommand(template: String) -> CustomSlashCommand {
        CustomSlashCommand(name: "test", description: "", promptTemplate: template)
    }

    private func makeContext(
        query: String? = nil,
        schema: String? = nil,
        database: String? = nil,
        body: String = ""
    ) -> CustomSlashCommandRenderer.Context {
        .init(query: query, schema: schema, database: database, body: body)
    }

    @Test("Substitutes a single placeholder")
    func substitutesSingle() {
        let result = CustomSlashCommandRenderer.render(
            makeCommand(template: "Run: {{query}}"),
            context: makeContext(query: "SELECT 1")
        )
        #expect(result == "Run: SELECT 1")
    }

    @Test("Substitutes multiple placeholders independently")
    func substitutesMultiple() {
        let result = CustomSlashCommandRenderer.render(
            makeCommand(template: "DB={{database}} | Q={{query}} | B={{body}}"),
            context: makeContext(query: "SELECT 1", database: "main", body: "extra")
        )
        #expect(result == "DB=main | Q=SELECT 1 | B=extra")
    }

    @Test("Missing values render as empty strings")
    func missingValuesAreEmpty() {
        let result = CustomSlashCommandRenderer.render(
            makeCommand(template: "schema={{schema}}, q={{query}}"),
            context: makeContext()
        )
        #expect(result == "schema=, q=")
    }

    @Test("Unknown placeholders pass through unchanged")
    func unknownPlaceholdersPassThrough() {
        let result = CustomSlashCommandRenderer.render(
            makeCommand(template: "{{query}} and {{notARealVar}}"),
            context: makeContext(query: "x")
        )
        #expect(result == "x and {{notARealVar}}")
    }

    @Test("Placeholder text inside a substituted value is not re-expanded")
    func noRecursiveExpansion() {
        // body contains literal `{{query}}` text. It should remain literal,
        // not get replaced by the query variable on a later pass.
        let result = CustomSlashCommandRenderer.render(
            makeCommand(template: "Body: {{body}}"),
            context: makeContext(query: "SELECT 1", body: "fix this {{query}}")
        )
        #expect(result == "Body: fix this {{query}}")
    }

    @Test("Empty template returns empty string")
    func emptyTemplate() {
        let result = CustomSlashCommandRenderer.render(
            makeCommand(template: ""),
            context: makeContext(query: "SELECT 1")
        )
        #expect(result == "")
    }

    @Test("Template without placeholders is returned verbatim")
    func noPlaceholders() {
        let result = CustomSlashCommandRenderer.render(
            makeCommand(template: "just literal text"),
            context: makeContext(query: "ignored")
        )
        #expect(result == "just literal text")
    }
}
