//
//  SSHConfigTokensTests.swift
//  TableProTests
//
//  Every expectation here was measured against OpenSSH_10.3p1 with `ssh -G`, or with `ssh -v`
//  against a local listener for the fields `-G` prints unexpanded.
//

import Foundation
@testable import TablePro
import Testing

@Suite("SSH config tokens")
struct SSHConfigTokensTests {
    private static let context = SSHTokenContext(
        originalHost: "tok",
        hostname: "127.0.0.1",
        port: 2_222,
        remoteUser: "bob",
        jumpHost: "jbox",
        hostKeyAlias: nil,
        localUser: "ngoquocdat",
        localHostname: "Mac"
    )

    @Test("Every token in the standard scope takes its measured value")
    func standardTokens() throws {
        let expansions: [(String, String)] = [
            ("%h", "127.0.0.1"),
            ("%n", "tok"),
            ("%p", "2222"),
            ("%r", "bob"),
            ("%u", "ngoquocdat"),
            ("%l", "Mac"),
            ("%L", "Mac"),
            ("%j", "jbox"),
            ("%k", "tok"),
            ("%%", "%"),
        ]
        for (input, expected) in expansions {
            let actual = try Self.context.expand(input, scope: .standard, keyword: "IdentityFile")
            #expect(actual == expected, "\(input) expanded to \(actual)")
        }
    }

    @Test("%d is the local home directory")
    func homeDirectoryToken() throws {
        let expanded = try Self.context.expand("%d/.ssh/key", scope: .standard, keyword: "IdentityFile")
        #expect(expanded == "\(SSHTokenContext.localHomeDirectory)/.ssh/key")
    }

    @Test("%i is the local user ID")
    func userIdentifierToken() throws {
        let expanded = try Self.context.expand("%i", scope: .standard, keyword: "IdentityFile")
        #expect(expanded == String(getuid()))
    }

    /// `ssh -v` printed `/Users/…/.ssh/tok_6a6931654bbdcabda8a3566634df2bbb00e56137.pem` for this
    /// exact host, port, user and jump host, so the hash and its basis are pinned to that run.
    @Test("%C is the SHA-1 of %l%h%p%r%j")
    func connectionHashToken() throws {
        let expanded = try Self.context.expand("%C", scope: .standard, keyword: "IdentityFile")
        #expect(expanded == "6a6931654bbdcabda8a3566634df2bbb00e56137")
    }

    @Test("%C with no jump host still matches ssh")
    func connectionHashWithoutJumpHost() throws {
        var context = Self.context
        context.jumpHost = nil
        let expanded = try context.expand("%C", scope: .standard, keyword: "IdentityFile")
        #expect(expanded == "d11c922fc1a8a0dd72dfb17799c7547cd7dbccdf")
    }

    @Test("%k falls back to the original host when no HostKeyAlias is set")
    func hostKeyAliasFallback() throws {
        var context = Self.context
        context.hostKeyAlias = "alias.example.com"
        let expanded = try context.expand("%k", scope: .standard, keyword: "IdentityFile")
        #expect(expanded == "alias.example.com")
    }

    @Test("Hostname accepts only %% and %h")
    func hostnameScope() throws {
        let expanded = try Self.context.expand("zzz-%h", scope: .hostname, keyword: "HostName")
        #expect(expanded == "zzz-127.0.0.1")

        #expect(throws: SSHTokenExpansionError.unsupportedToken(keyword: "HostName", token: "%d")) {
            try Self.context.expand("%d", scope: .hostname, keyword: "HostName")
        }
        #expect(throws: SSHTokenExpansionError.unsupportedToken(keyword: "HostName", token: "%n")) {
            try Self.context.expand("pre-%n", scope: .hostname, keyword: "HostName")
        }
    }

    @Test("ProxyJump accepts %%, %h, %n, %p and %r but not %C")
    func proxyScope() throws {
        let expanded = try Self.context.expand("%r@jump-%h-%n-%p", scope: .proxy, keyword: "ProxyJump")
        #expect(expanded == "bob@jump-127.0.0.1-tok-2222")

        #expect(throws: SSHTokenExpansionError.unsupportedToken(keyword: "ProxyJump", token: "%C")) {
            try Self.context.expand("box-%C", scope: .proxy, keyword: "ProxyJump")
        }
    }

    /// The document is parsed once and shared by every connection, so no target is known while an
    /// `Include` resolves. Expanding `%h` to an empty string there would silently read the wrong file.
    @Test("Include takes only the tokens that do not name a target")
    func includeScope() throws {
        let expanded = try Self.context.expand("%d/.ssh/conf.d/%u.conf", scope: .includePath, keyword: "Include")
        #expect(expanded == "\(SSHTokenContext.localHomeDirectory)/.ssh/conf.d/ngoquocdat.conf")

        #expect(throws: SSHTokenExpansionError.unsupportedToken(keyword: "Include", token: "%h")) {
            try Self.context.expand("conf.d/%h.conf", scope: .includePath, keyword: "Include")
        }
    }

    @Test("A lone trailing percent is rejected, the way ssh rejects it")
    func danglingPercent() {
        #expect(throws: SSHTokenExpansionError.danglingPercent(keyword: "HostName")) {
            try Self.context.expand("ab%", scope: .hostname, keyword: "HostName")
        }
        #expect(throws: SSHTokenExpansionError.danglingPercent(keyword: "HostName")) {
            try Self.context.expand("%", scope: .hostname, keyword: "HostName")
        }
    }

    @Test("%% is consumed before the token after it")
    func literalPercentBeforeToken() throws {
        let expanded = try Self.context.expand("%%%h", scope: .standard, keyword: "IdentityFile")
        #expect(expanded == "%127.0.0.1")
    }

    /// One left-to-right pass. Expanding token by token in sequence let a substituted value be
    /// rescanned, so a home directory holding the two characters `%h` came back with the hostname
    /// spliced into it.
    @Test("A substituted value is never rescanned for tokens")
    func substitutedValuesAreNotRescanned() throws {
        var context = Self.context
        context.remoteUser = "%h"
        let expanded = try context.expand("%r", scope: .standard, keyword: "IdentityFile")
        #expect(expanded == "%h")
    }

    @Test("An empty value expands to itself")
    func emptyValue() throws {
        let expanded = try Self.context.expand("", scope: .standard, keyword: "IdentityFile")
        #expect(expanded.isEmpty)
    }

    @Test("A path with no token is returned unchanged")
    func valueWithoutTokens() throws {
        let expanded = try Self.context.expand("/keys/id_rsa", scope: .standard, keyword: "IdentityFile")
        #expect(expanded == "/keys/id_rsa")
    }

    @Test("${VAR} expands from the environment")
    func environmentVariable() throws {
        let expanded = try Self.context.expand("${HOME}/env.pem", scope: .standard, keyword: "IdentityFile")
        #expect(expanded == "\(ProcessInfo.processInfo.environment["HOME"] ?? "")/env.pem")
    }

    @Test("An unset ${VAR} is reported rather than left in the path")
    func undefinedEnvironmentVariable() {
        let name = "TABLEPRO_DEFINITELY_UNSET_VARIABLE"
        #expect(throws: SSHTokenExpansionError.undefinedEnvironmentVariable(keyword: "IdentityFile", name: name)) {
            try Self.context.expand("${\(name)}/k.pem", scope: .standard, keyword: "IdentityFile")
        }
    }

    @Test("A bare dollar sign is not an environment reference")
    func bareDollarSign() throws {
        let expanded = try Self.context.expand("/keys/a$b", scope: .standard, keyword: "IdentityFile")
        #expect(expanded == "/keys/a$b")
    }

    /// ssh_config(5) names the keywords that take `${VAR}`, and `Match exec` is not one: the
    /// command goes to the shell with its dollar expressions intact.
    @Test("Match exec keeps ${...} rather than expanding it")
    func matchExecScopeLeavesEnvironmentAlone() throws {
        let command = "test x${TABLEPRO_MODE:-dev} = xdev"
        let expanded = try Self.context.expand(command, scope: .matchExec, keyword: "Match exec")
        #expect(expanded == command)
    }

    @Test("Hostname and ProxyJump keep ${...} too")
    func hostnameAndProxyScopesLeaveEnvironmentAlone() throws {
        #expect(try Self.context.expand("${HOME}.example.com", scope: .hostname, keyword: "HostName")
            == "${HOME}.example.com")
        #expect(try Self.context.expand("${HOME}", scope: .proxy, keyword: "ProxyJump") == "${HOME}")
    }

    @Test("Match exec still takes the full token set")
    func matchExecScopeKeepsTokens() throws {
        let expanded = try Self.context.expand("probe %h %p %r", scope: .matchExec, keyword: "Match exec")
        #expect(expanded == "probe 127.0.0.1 2222 bob")
    }

    /// ssh refuses to run on `${HOME`: "Invalid environment expansion". Copying the dollar sign
    /// through instead left a malformed path to fail later as an authentication error.
    @Test("A ${ with no closing brace is reported")
    func malformedEnvironmentReference() {
        #expect(throws: SSHTokenExpansionError.malformedEnvironmentReference(keyword: "IdentityAgent")) {
            try Self.context.expand("${HOME", scope: .standard, keyword: "IdentityAgent")
        }
        #expect(throws: SSHTokenExpansionError.malformedEnvironmentReference(keyword: "IdentityAgent")) {
            try Self.context.expand("${}", scope: .standard, keyword: "IdentityAgent")
        }
    }

    @Test("A missing token value expands to empty rather than failing")
    func absentTokenValue() throws {
        let context = SSHTokenContext(originalHost: "tok", hostname: nil, localUser: "u", localHostname: "Mac")
        let expanded = try context.expand("/keys/%h", scope: .standard, keyword: "IdentityFile")
        #expect(expanded == "/keys/")
    }

    /// ssh reads `%l` from `gethostname(3)`. `ProcessInfo.processInfo.hostName` returns the Bonjour
    /// name instead, and the two differ on a stock Mac, which changes `%C` silently.
    @Test("The local hostname comes from gethostname")
    func systemHostnameMatchesGethostname() {
        var buffer = [CChar](repeating: 0, count: 256)
        _ = gethostname(&buffer, buffer.count)
        #expect(SSHTokenContext.systemHostname() == String(cString: buffer))
    }
}

@Suite("SSH path utilities")
struct SSHPathExpansionTests {
    @Test("A leading tilde expands to the home directory")
    func expandsTilde() {
        #expect(SSHPathUtilities.expandTilde("~/.ssh/id_rsa") == "\(NSHomeDirectory())/.ssh/id_rsa")
        #expect(SSHPathUtilities.expandTilde("~") == NSHomeDirectory())
    }

    @Test("An absolute path is unchanged")
    func leavesAbsolutePaths() {
        #expect(SSHPathUtilities.expandTilde("/etc/ssh/id_rsa") == "/etc/ssh/id_rsa")
    }

    /// ssh resolved `IdentityAgent ~root/agent.sock` to `/var/root/agent.sock`, so `~user` counts.
    @Test("~user expands to that user's home directory")
    func expandsNamedUser() {
        #expect(SSHPathUtilities.expandTilde("~root/x") == "/var/root/x")
    }

    @Test("A tilde that is not leading stays put")
    func leavesInteriorTilde() {
        #expect(SSHPathUtilities.expandTilde("/keys/a~b") == "/keys/a~b")
    }

    @Test("An unknown user is left alone rather than resolved to nothing")
    func leavesUnknownUser() {
        #expect(SSHPathUtilities.expandTilde("~nosuchuser99/x") == "~nosuchuser99/x")
    }
}
