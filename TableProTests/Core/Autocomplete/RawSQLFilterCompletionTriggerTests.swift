//
//  RawSQLFilterCompletionTriggerTests.swift
//  TableProTests
//
//  Which filter-bar positions open the popup on their own. The field is one WHERE clause, so the
//  rule it follows has to be the editor's: the same fragment cannot open a list in one surface and
//  nothing in the other.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Raw SQL Filter Completion Trigger")
struct RawSQLFilterCompletionTriggerTests {
    private static func dialect(identifierQuote: String, dataTypes: Set<String>) -> SQLDialectDescriptor {
        SQLDialectDescriptor(
            identifierQuote: identifierQuote, keywords: [], functions: [], dataTypes: dataTypes,
            regexSyntax: .tilde, booleanLiteralStyle: .truefalse,
            likeEscapeStyle: .explicit, paginationStyle: .limit,
            offsetFetchOrderBy: "ORDER BY 1", requiresBackslashEscaping: false,
            autoLimitStyle: .limit
        )
    }

    private static func engine(dataTypes: Set<String> = []) -> CompletionEngine {
        CompletionEngine(
            schemaProvider: nil,
            databaseType: .postgresql,
            dialect: dialect(identifierQuote: "\"", dataTypes: dataTypes),
            statementCompletions: []
        )
    }

    /// Asked of the engine the surface calls, not of the rule by hand: the rule has its own suite,
    /// and what this pins is that the filter path is wired to it.
    ///
    /// The explicit request separates a position the rule declined from one that simply had nothing
    /// to offer, which a nil alone cannot.
    private static func suppresses(_ fragment: String, dataTypes: Set<String> = []) async -> Bool? {
        let engine = engine(dataTypes: dataTypes)
        let cursor = (fragment as NSString).length
        guard await engine.filterCompletions(
            fragment: fragment, cursorPosition: cursor, tableName: "regions", trigger: .explicit
        ) != nil else { return nil }

        return await engine.filterCompletions(
            fragment: fragment, cursorPosition: cursor, tableName: "regions", trigger: .automatic
        ) == nil
    }

    @Test(
        "A finished condition leaves the list closed so Return applies the filter",
        arguments: [
            "region='EU'",
            "region='O''Brien'",
            "region IN ('EU')",
            "id = 1 AND ",
            "region='EU' AND "
        ]
    )
    func finishedConditionStaysShut(fragment: String) async {
        #expect(await Self.suppresses(fragment) == true)
    }

    @Test(
        "Typing a token still opens the list",
        arguments: ["reg", "region='EU' AND na", "id = 1 AND cre"]
    )
    func typingATokenOpensTheList(fragment: String) async {
        #expect(await Self.suppresses(fragment) == false)
    }

    /// #2925 landed the cast list in the editor, and the filter bar has to keep it: `:` is a
    /// trigger character and the type list is the short, closed answer the auto-open rule is for.
    @Test("A PostgreSQL cast opens the type list with nothing typed")
    func castTargetOpensOnAnEmptyPrefix() async {
        #expect(await Self.suppresses("id::", dataTypes: ["integer", "jsonb"]) == false)
    }

    @MainActor
    @Test("The provider applies the rule, so a finished condition returns nothing to show")
    func providerSuppressesAFinishedCondition() async {
        let provider = RawSQLFilterCompletionProvider(
            schemaProvider: SQLSchemaProvider(),
            databaseType: .postgresql,
            tableName: "regions",
            profile: QueryCompletionProfile(
                resolvedDialect: Self.dialect(identifierQuote: "\"", dataTypes: ["integer", "jsonb"]),
                statementCompletions: []
            )
        )

        let fragment = "region='EU'"
        let finished = await provider.completions(fieldText: fragment, cursor: (fragment as NSString).length)
        #expect(finished == nil)

        let cast = await provider.completions(fieldText: "id::", cursor: 4)
        #expect(cast?.items.contains { $0.label == "jsonb" } == true)
    }
}
