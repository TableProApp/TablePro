//
//  SlashCommandTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SlashCommand")
struct SlashCommandTests {
    @Test("parse recognizes known commands at the start of input")
    func parsesKnownCommand() {
        #expect(SlashCommand.parse("/explain")?.name == "explain")
        #expect(SlashCommand.parse("/optimize")?.name == "optimize")
        #expect(SlashCommand.parse("/fix")?.name == "fix")
        #expect(SlashCommand.parse("/help")?.name == "help")
    }

    @Test("parse is case-insensitive on the name")
    func parseCaseInsensitive() {
        #expect(SlashCommand.parse("/Explain")?.name == "explain")
        #expect(SlashCommand.parse("/HELP")?.name == "help")
    }

    @Test("parse trims surrounding whitespace before matching")
    func parseTrimsWhitespace() {
        #expect(SlashCommand.parse("  /explain  ")?.name == "explain")
        #expect(SlashCommand.parse("\n/help\n")?.name == "help")
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
        #expect(filtered.first?.name == "explain")

        #expect(SlashCommand.match(prefix: "/zzz").isEmpty)
        #expect(SlashCommand.match(prefix: "ex").isEmpty)
    }
}
