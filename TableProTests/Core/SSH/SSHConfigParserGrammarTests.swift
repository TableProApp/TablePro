//
//  SSHConfigParserGrammarTests.swift
//  TableProTests
//
//  The parts of ssh_config(5)'s grammar TablePro used to read differently from ssh. Each case names
//  what OpenSSH_10.3p1 reported for the same file.
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("SSH config parser grammar")
struct SSHConfigParserGrammarTests {
    private static let env = ResolverEnvironment(
        runShell: { _ in true },
        canonicalize: { host, _ in host },
        currentLocalUser: { "tester" },
        localHostname: { "Mac" }
    )

    private func resolve(_ content: String, host: String, baseDir: URL? = nil) -> ResolvedSSHTarget {
        var config = SSHConfiguration()
        config.enabled = true
        config.host = host
        return SSHConfigResolver.resolve(
            config,
            document: SSHConfigParser.parseDocumentContent(content, baseDir: baseDir),
            env: Self.env
        )
    }

    // MARK: - Comments

    /// `ssh -G db` reported `db.example.com`, 7777 and `bob`. Keeping the comment in the value sent
    /// `db.example.com   # production` to getaddrinfo, which is the reported bug from a second
    /// cause, and made `Port 7777 # c` fall back to 22 because the number no longer parsed.
    @Test("A trailing comment is not part of the value")
    func trailingCommentIsDropped() {
        let resolved = resolve(
            """
            Host db
                HostName db.example.com   # production
                Port 7777 # the tunnel
                User bob   # not a comment reader
            """,
            host: "db"
        )
        #expect(resolved.host == "db.example.com")
        #expect(resolved.port == 7_777)
        #expect(resolved.username == "bob")
    }

    /// A `#` only opens a comment where it starts an argument, measured: ssh kept this one.
    @Test("A hash inside a word stays in the value")
    func embeddedHashIsKept() {
        let resolved = resolve(
            """
            Host db
                HostName db.example.com#keepme
            """,
            host: "db"
        )
        #expect(resolved.host == "db.example.com#keepme")
    }

    @Test("A hash inside quotes stays in the value")
    func quotedHashIsKept() {
        let resolved = resolve(
            """
            Host db
                HostName "db#1.example.com"
            """,
            host: "db"
        )
        #expect(resolved.host == "db#1.example.com")
    }

    @Test("A whole-line comment is still skipped")
    func fullLineCommentIsSkipped() {
        let resolved = resolve(
            """
            # Host other
            Host db
                # HostName wrong.example.com
                HostName db.example.com
            """,
            host: "db"
        )
        #expect(resolved.host == "db.example.com")
    }

    @Test("CRLF line endings parse the same as LF")
    func carriageReturnsAreTolerated() {
        let resolved = resolve("Host db\r\n    HostName db.example.com\r\n    Port 2345\r\n", host: "db")
        #expect(resolved.host == "db.example.com")
        #expect(resolved.port == 2_345)
    }

    // MARK: - Pattern lists

    /// `ssh -G a` gave port 22: a `Host` line is a whitespace-separated list, so the comma is an
    /// ordinary character and `Host a,b` matches a host literally called `a,b`.
    @Test("A Host line separates patterns on whitespace, not commas")
    func hostPatternListUsesWhitespace() {
        let content = """
        Host a,b
            Port 2401
        """
        #expect(resolve(content, host: "a").port == 22)
        #expect(resolve(content, host: "b").port == 22)
        #expect(resolve(content, host: "a,b").port == 2_401)
    }

    @Test("A Host line with several patterns matches each of them")
    func hostPatternListMatchesEachEntry() {
        let content = """
        Host a b
            Port 2402
        """
        #expect(resolve(content, host: "a").port == 2_402)
        #expect(resolve(content, host: "b").port == 2_402)
    }

    /// `Match host a,b` matched both, so that list is comma-separated where `Host` is not.
    @Test("A Match host argument separates patterns on commas")
    func matchPatternListUsesCommas() {
        let content = """
        Match host a,b
            Port 2403
        """
        #expect(resolve(content, host: "a").port == 2_403)
        #expect(resolve(content, host: "b").port == 2_403)
        #expect(resolve(content, host: "c").port == 22)
    }

    /// `Host EXAMPLE.com` did not match `example.com`, so this one stays case-sensitive.
    @Test("Host patterns are case-sensitive")
    func hostPatternsAreCaseSensitive() {
        let content = """
        Host EXAMPLE.com
            Port 2299
        """
        #expect(resolve(content, host: "example.com").port == 22)
        #expect(resolve(content, host: "EXAMPLE.com").port == 2_299)
    }

    @Test("A negated Host pattern still excludes")
    func negatedHostPattern() {
        let content = """
        Host *.example.com !secret.example.com
            Port 2404
        """
        #expect(resolve(content, host: "ok.example.com").port == 2_404)
        #expect(resolve(content, host: "secret.example.com").port == 22)
    }

    // MARK: - Include

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) rethrows {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ssh-include-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func write(_ contents: String, named name: String, in directory: URL) -> URL {
        let url = directory.appendingPathComponent(name)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// `Include a b` reads both. Globbing the whole line as one pattern returned `GLOB_NOMATCH`, so
    /// neither file contributed and nothing was logged.
    @Test("Include reads every path on the line")
    func includeReadsSeveralPaths() {
        withTemporaryDirectory { directory in
            let one = write("User oneuser\n", named: "c_one", in: directory)
            let two = write("Port 3333\n", named: "c_two", in: directory)
            let resolved = resolve(
                "Include \(one.path) \(two.path)",
                host: "h",
                baseDir: directory
            )
            #expect(resolved.username == "oneuser")
            #expect(resolved.port == 3_333)
        }
    }

    /// An `Include` inside a `Host` block applies to that block, the way it would if the lines were
    /// written there. Splicing the parsed blocks in instead turned the included file's bare
    /// directives into a global block, so a production key reached every other connection.
    @Test("An Include inside a Host block stays inside it")
    func includeInsideHostBlockIsScoped() {
        withTemporaryDirectory { directory in
            let secrets = write("User produser\nPort 2200\n", named: "prod.conf", in: directory)
            let content = """
            Host prod
                HostName prod.example.com
                Include \(secrets.path)
            Host staging
                HostName staging.example.com
            """
            #expect(resolve(content, host: "prod", baseDir: directory).username == "produser")

            let staging = resolve(content, host: "staging", baseDir: directory)
            #expect(staging.username.isEmpty)
            #expect(staging.port == 22)
        }
    }

    /// The same snippet is legitimately included from several blocks. Keeping every file ever read
    /// in the cycle guard made every occurrence after the first contribute nothing.
    @Test("The same file can be included from more than one block")
    func includeIsReusableAcrossBlocks() {
        withTemporaryDirectory { directory in
            let common = write("Port 2500\n", named: "common.conf", in: directory)
            let content = """
            Host first
                Include \(common.path)
            Host second
                Include \(common.path)
            """
            #expect(resolve(content, host: "first", baseDir: directory).port == 2_500)
            #expect(resolve(content, host: "second", baseDir: directory).port == 2_500)
        }
    }

    @Test("An Include after a block does not outrank it")
    func includeKeepsFirstWins() {
        withTemporaryDirectory { directory in
            let extra = write("Host myserver\n    User extrauser\n", named: "extra.conf", in: directory)
            let content = """
            Host *
                User defaultuser
            Include \(extra.path)
            """
            #expect(resolve(content, host: "myserver", baseDir: directory).username == "defaultuser")
        }
    }

    @Test("A circular Include terminates")
    func circularIncludeTerminates() {
        withTemporaryDirectory { directory in
            let loop = directory.appendingPathComponent("loop.conf")
            try? "Include \(loop.path)\nPort 2600\n".write(to: loop, atomically: true, encoding: .utf8)
            #expect(resolve("Include \(loop.path)", host: "h", baseDir: directory).port == 2_600)
        }
    }

    /// The document is parsed once for every connection, so a token naming the target cannot be
    /// resolved while an `Include` is read. Expanding it to an empty string would read the wrong file.
    @Test("An Include naming the target is skipped rather than misread")
    func includeWithHostTokenIsSkipped() {
        withTemporaryDirectory { directory in
            _ = write("Port 2700\n", named: ".conf", in: directory)
            let resolved = resolve(
                "Include \(directory.path)/%h.conf",
                host: "h",
                baseDir: directory
            )
            #expect(resolved.port == 22)
        }
    }

    @Test("Include expands the tokens that do not name the target")
    func includeExpandsHostIndependentTokens() {
        withTemporaryDirectory { directory in
            _ = write("Port 2800\n", named: "\(NSUserName()).conf", in: directory)
            let resolved = resolve(
                "Include \(directory.path)/%u.conf",
                host: "h",
                baseDir: directory
            )
            #expect(resolved.port == 2_800)
        }
    }

    // MARK: - ProxyJump

    /// ssh accepts a bare IPv6 from an expanded `%h`. Reading the last group as a port left `::`
    /// as the host and `1` as the port.
    @Test("An unbracketed IPv6 ProxyJump keeps its address")
    func proxyJumpAcceptsBareIPv6() {
        let hops = SSHConfigParser.parseProxyJump("::1")
        #expect(hops.count == 1)
        #expect(hops.first?.host == "::1")
        #expect(hops.first?.port == nil)
    }

    /// `%r` expands to the remote username, and a UPN-style one carries its own `@`.
    @Test("A username containing an at sign still separates from the host")
    func proxyJumpSplitsOnTheLastAtSign() {
        let hops = SSHConfigParser.parseProxyJump("user@corp.local@bastion")
        #expect(hops.count == 1)
        #expect(hops.first?.username == "user@corp.local")
        #expect(hops.first?.host == "bastion")
    }

    @Test("A bracketed IPv6 with a port still parses")
    func proxyJumpBracketedIPv6() {
        let hops = SSHConfigParser.parseProxyJump("[fe80::1]:2200")
        #expect(hops.first?.host == "fe80::1")
        #expect(hops.first?.port == 2_200)
    }

    @Test("A plain host and port still parses")
    func proxyJumpHostAndPort() {
        let hops = SSHConfigParser.parseProxyJump("ops@bastion.example.com:2200")
        #expect(hops.first?.username == "ops")
        #expect(hops.first?.host == "bastion.example.com")
        #expect(hops.first?.port == 2_200)
    }
}
