//
//  TunnelCommandLineTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Tunnel command line")
struct TunnelCommandLineTests {
    @Test("splits on whitespace")
    func splitsOnWhitespace() throws {
        let tokens = try TunnelCommandLine.tokenize("kubectl  port-forward\tsvc/pg 1:2")
        #expect(tokens == ["kubectl", "port-forward", "svc/pg", "1:2"])
    }

    @Test("keeps a quoted argument whole")
    func keepsQuotedArgumentWhole() throws {
        #expect(try TunnelCommandLine.tokenize("ssh -o 'ProxyCommand nc %h %p' host")
            == ["ssh", "-o", "ProxyCommand nc %h %p", "host"])
        #expect(try TunnelCommandLine.tokenize("a \"b c\" d") == ["a", "b c", "d"])
    }

    @Test("keeps an empty quoted argument")
    func keepsEmptyQuotedArgument() throws {
        #expect(try TunnelCommandLine.tokenize("cmd '' x") == ["cmd", "", "x"])
    }

    @Test("honours escapes inside and outside double quotes")
    func honoursEscapes() throws {
        #expect(try TunnelCommandLine.tokenize(#"cmd a\ b"#) == ["cmd", "a b"])
        #expect(try TunnelCommandLine.tokenize(#"cmd "say \"hi\"""#) == ["cmd", #"say "hi""#])
        #expect(try TunnelCommandLine.tokenize(#"cmd 'a\b'"#) == ["cmd", #"a\b"#])
    }

    @Test("expands a leading tilde")
    func expandsLeadingTilde() throws {
        let tokens = try TunnelCommandLine.tokenize("~/bin/forward --config ~/conf")
        #expect(tokens[0] == (NSHomeDirectory() as NSString).appendingPathComponent("bin/forward"))
        #expect(tokens[2] == (NSHomeDirectory() as NSString).appendingPathComponent("conf"))
    }

    @Test("does not expand shell syntax")
    func doesNotExpandShellSyntax() throws {
        #expect(try TunnelCommandLine.tokenize("cmd $HOME $(whoami) *") == ["cmd", "$HOME", "$(whoami)", "*"])
    }

    @Test("rejects an unclosed quote or a trailing backslash")
    func rejectsUnbalanced() {
        #expect(throws: TunnelCommandLine.ParseError.unbalancedQuote) {
            _ = try TunnelCommandLine.tokenize("cmd 'unterminated")
        }
        #expect(throws: TunnelCommandLine.ParseError.unbalancedQuote) {
            _ = try TunnelCommandLine.tokenize(#"cmd trailing\"#)
        }
    }

    @Test("rejects a command with no words")
    func rejectsEmpty() {
        #expect(throws: TunnelCommandLine.ParseError.empty) {
            _ = try TunnelCommandLine.tokenize("   ")
        }
    }

    /// Substituting after the split is what stops a host carrying a space from becoming two
    /// arguments, which is the whole reason the two steps are separate.
    @Test("substitution cannot split a token")
    func substitutionCannotSplitAToken() throws {
        let tokens = try TunnelCommandLine.tokenize("cmd --to={host}:{remotePort} --listen={port}")
        let substituted = TunnelCommandLine.substitutePlaceholders(
            in: tokens,
            localPort: 55_000,
            remoteHost: "db one",
            remotePort: 5_432
        )
        #expect(substituted == ["cmd", "--to=db one:5432", "--listen=55000"])
    }
}
