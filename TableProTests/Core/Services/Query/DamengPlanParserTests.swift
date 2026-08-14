//
//  DamengPlanParserTests.swift
//  TableProTests
//

@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Dameng Plan Parser")
struct DamengPlanParserTests {
    private let parser = DamengPlanParser()

    @Test("Parses numeric prefixes and indentation as a tree")
    func parsesHierarchy() throws {
        let text = [
            "1   #NSET2: [1, 1, 108]",
            "2     #PRJT2: [1, 1, 108]; exp_num(3)",
            "3       #CSCN2: [1, 1, 108]; TABLEPRO_TEST",
        ].joined(separator: "\n")

        let plan = try #require(parser.parse(rawText: text))

        #expect(plan.rootNode.operation == "NSET2")
        #expect(plan.rootNode.properties["Details"] == "[1, 1, 108]")
        #expect(plan.rootNode.children.first?.operation == "PRJT2")
        #expect(plan.rootNode.children.first?.children.first?.operation == "CSCN2")
    }

    @Test("Ignores malformed non-plan lines")
    func ignoresMalformedLines() {
        #expect(parser.parse(rawText: "not a DM8 plan") == nil)
        #expect(parser.parse(rawText: "1   missing marker") == nil)
    }

    @Test("Registry returns the Dameng parser")
    func registryReturnsDamengParser() {
        #expect(ExplainPlanParserRegistry.parser(for: .damengText) is DamengPlanParser)
        #expect(ExplainFormatResolver.resolve(declared: .damengText, databaseType: .dameng) == .damengText)
    }
}
