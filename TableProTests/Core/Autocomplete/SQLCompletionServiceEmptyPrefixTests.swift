//
//  SQLCompletionServiceEmptyPrefixTests.swift
//  TableProTests
//
//  Which cursor positions open the popup with nothing typed. The list is deliberately short: a
//  clause with a full column list behind it stays shut until the user types or presses Ctrl+Space.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct SQLCompletionServiceEmptyPrefixTests {
    private static func dialect(dataTypes: Set<String>) -> SQLDialectDescriptor {
        SQLDialectDescriptor(
            identifierQuote: "\"", keywords: [], functions: [], dataTypes: dataTypes,
            regexSyntax: .tilde, booleanLiteralStyle: .truefalse,
            likeEscapeStyle: .explicit, paginationStyle: .limit,
            offsetFetchOrderBy: "ORDER BY 1", requiresBackslashEscaping: false,
            autoLimitStyle: .limit
        )
    }

    @MainActor
    private static func makeService() -> SQLCompletionService {
        SQLCompletionService(
            schemaProvider: nil,
            databaseType: .postgresql,
            profile: QueryCompletionProfile(
                resolvedDialect: dialect(dataTypes: ["integer", "jsonb", "timestamptz"]),
                statementCompletions: []
            )
        )
    }

    /// `:` is a trigger character, and the cast list is the short, closed answer the auto-open
    /// list is for. It was the one clause the list left out, so the trigger opened nothing.
    @MainActor
    @Test("A PostgreSQL cast opens the type list with nothing typed")
    func castTargetOpensOnAnEmptyPrefix() async {
        let text = "SELECT id::" as NSString
        let session = await Self.makeService().completions(in: text, at: text.length, isManualTrigger: false)

        #expect(session != nil)
        #expect(session?.items.contains { $0.label == "jsonb" } == true)
    }

    @MainActor
    @Test("A partly typed cast still completes")
    func castTargetCompletesATypedPrefix() async {
        let text = "SELECT id::js" as NSString
        let session = await Self.makeService().completions(in: text, at: text.length, isManualTrigger: false)

        #expect(session?.items.first?.label == "jsonb")
    }

    @MainActor
    @Test(
        "A clause with a full list behind it stays shut until it is asked",
        arguments: [
            "SELECT * FROM users WHERE ",
            "SELECT * FROM users WHERE id = 1 AND ",
            "SELECT * FROM users HAVING "
        ]
    )
    func noisyClausesStaySuppressed(query: String) async {
        let text = query as NSString
        let service = Self.makeService()

        let automatic = await service.completions(in: text, at: text.length, isManualTrigger: false)
        #expect(automatic == nil)

        let manual = await service.completions(in: text, at: text.length, isManualTrigger: true)
        #expect(manual != nil)
    }

    @MainActor
    @Test("FROM still opens with nothing typed")
    func fromOpensOnAnEmptyPrefix() async {
        let text = "SELECT * FROM " as NSString
        let session = await Self.makeService().completions(in: text, at: text.length, isManualTrigger: false)

        #expect(session != nil)
    }
}
