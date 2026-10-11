//
//  SlashCommandTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct SlashCommandTests {
    @Test("parse recognizes known commands at the start of input")
    func parsesKnownCommand() {
        #expect(SlashCommand.parse("/explain")?.command == .explain)
        #expect(SlashCommand.parse("/optimize")?.command == .optimize)
        #expect(SlashCommand.parse("/fix")?.command == .fix)
        #expect(SlashCommand.parse("/help")?.command == .help)
    }

    @Test("parse extracts the body after the command name")
    func parseExtractsBody() {
        let parsed = SlashCommand.parse("/explain SELECT * FROM users")
        #expect(parsed?.command == .explain)
        #expect(parsed?.body == "SELECT * FROM users")

        let bare = SlashCommand.parse("/explain")
        #expect(bare?.body == "")

        let bodyOnly = SlashCommand.parse("/fix    extra   whitespace   ")
        #expect(bodyOnly?.body == "extra   whitespace")
    }

    @Test("parse is case-insensitive on the command name only")
    func parseCaseInsensitive() {
        #expect(SlashCommand.parse("/Explain")?.command == .explain)
        #expect(SlashCommand.parse("/HELP")?.command == .help)
        let parsed = SlashCommand.parse("/EXPLAIN SELECT 1")
        #expect(parsed?.command == .explain)
        #expect(parsed?.body == "SELECT 1")
    }

    @Test("parse trims surrounding whitespace before matching")
    func parseTrimsWhitespace() {
        #expect(SlashCommand.parse("  /explain  ")?.command == .explain)
        #expect(SlashCommand.parse("\n/help\n")?.command == .help)
    }

    @Test("parse returns nil for non-slash input")
    func parseRejectsNonSlash() {
        #expect(SlashCommand.parse("explain") == nil)
        #expect(SlashCommand.parse("hello world") == nil)
        #expect(SlashCommand.parse("") == nil)
    }

    @Test("parse returns nil for unknown slash commands")
    func parseRejectsUnknown() {
        #expect(SlashCommand.parse("/notacommand") == nil)
        #expect(SlashCommand.parse("/sql") == nil)
    }

    @Test("match by typed prefix returns filtered results")
    func matchByPrefix() {
        let all = SlashCommand.match(prefix: "/")
        #expect(all.count == SlashCommand.allCommands.count)

        let filtered = SlashCommand.match(prefix: "/ex")
        #expect(filtered.count == 1)
        #expect(filtered.first == .explain)

        #expect(SlashCommand.match(prefix: "/zzz").isEmpty)
        #expect(SlashCommand.match(prefix: "ex").isEmpty)
    }

    @Test("requiresQuery is true for query-acting commands and false for help")
    func requiresQuerySemantics() {
        #expect(SlashCommand.explain.requiresQuery)
        #expect(SlashCommand.optimize.requiresQuery)
        #expect(SlashCommand.fix.requiresQuery)
        #expect(!SlashCommand.help.requiresQuery)
        #expect(SlashCommand.review.requiresQuery)
    }

    @Test("/review parses with its body and maps to the review action")
    func reviewParsesAndMaps() {
        let parsed = SlashCommand.parse("/review SELECT * FROM orders")
        #expect(parsed?.command == .review)
        #expect(parsed?.body == "SELECT * FROM orders")
        #expect(SlashCommand.review.queryAction == .review)
        #expect(SlashCommand.fix.queryAction == .fixError)
        #expect(SlashCommand.help.queryAction == nil)
    }

    @Test("A prefix of /re matches review only")
    func reviewPrefixMatch() {
        #expect(SlashCommand.match(prefix: "/re") == [.review])
    }

    @Test("Built-in names are recognised whatever their case or padding")
    func builtInNames() {
        #expect(SlashCommand.isBuiltIn(name: "review"))
        #expect(SlashCommand.isBuiltIn(name: " Review "))
        #expect(!SlashCommand.isBuiltIn(name: "summarize"))
    }

    @Test("The help text lists every built-in command")
    @MainActor
    func helpListsEveryCommand() {
        for command in SlashCommand.allCommands {
            #expect(AIChatViewModel.helpMarkdown.contains("/\(command.name)"))
        }
    }
}
