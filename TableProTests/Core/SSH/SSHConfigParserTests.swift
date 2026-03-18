//
//  SSHConfigParserTests.swift
//  TableProTests
//
//  Tests for SSH config file parsing
//

import Foundation
@testable import TablePro
import Testing

@Suite("SSH Config Parser")
struct SSHConfigParserTests {
    @Test("Empty content returns empty array")
    func testEmptyContent() {
        let result = SSHConfigParser.parseContent("")
        #expect(result.isEmpty)
    }

    @Test("Single host entry with all fields")
    func testSingleHostWithAllFields() {
        let content = """
        Host myserver
            HostName example.com
            Port 2222
            User admin
            IdentityFile ~/.ssh/id_rsa
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 1)

        let entry = result[0]
        #expect(entry.host == "myserver")
        #expect(entry.hostname == "example.com")
        #expect(entry.port == 2_222)
        #expect(entry.user == "admin")
        #expect(entry.identityFile != nil)
        #expect(entry.identityFile?.contains(".ssh/id_rsa") == true)
    }

    @Test("Multiple host entries")
    func testMultipleHostEntries() {
        let content = """
        Host server1
            HostName host1.com
            Port 22

        Host server2
            HostName host2.com
            Port 2222

        Host server3
            HostName host3.com
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 3)
        #expect(result[0].host == "server1")
        #expect(result[1].host == "server2")
        #expect(result[2].host == "server3")
        #expect(result[0].port == 22)
        #expect(result[1].port == 2_222)
    }

    @Test("Comments are skipped")
    func testCommentsAreSkipped() {
        let content = """
        # This is a comment
        Host myserver
            # Another comment
            HostName example.com
            # Port comment
            Port 2222
        # Final comment
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 1)
        #expect(result[0].host == "myserver")
        #expect(result[0].hostname == "example.com")
        #expect(result[0].port == 2_222)
    }

    @Test("Wildcard hosts with asterisk are skipped")
    func testWildcardHostsWithAsteriskAreSkipped() {
        let content = """
        Host *
            IdentityFile ~/.ssh/default_key

        Host *.example.com
            User admin

        Host myserver
            HostName example.com
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 1)
        #expect(result[0].host == "myserver")
    }

    @Test("Wildcard hosts with question mark are skipped")
    func testWildcardHostsWithQuestionMarkAreSkipped() {
        let content = """
        Host server?
            HostName example.com

        Host db??.prod
            User admin

        Host validhost
            HostName valid.com
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 1)
        #expect(result[0].host == "validhost")
    }

    @Test("Tilde expansion in IdentityFile path")
    func testTildeExpansionInIdentityFile() {
        let content = """
        Host myserver
            IdentityFile ~/keys/id_rsa
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 1)

        let homeDir = NSHomeDirectory()
        #expect(result[0].identityFile?.contains(homeDir) == true)
        #expect(result[0].identityFile?.contains("keys/id_rsa") == true)
    }

    @Test("Host without hostname")
    func testHostWithoutHostname() {
        let content = """
        Host myserver
            Port 2222
            User admin
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 1)
        #expect(result[0].host == "myserver")
        #expect(result[0].hostname == nil)
        #expect(result[0].port == 2_222)
        #expect(result[0].user == "admin")
    }

    @Test("Host without port")
    func testHostWithoutPort() {
        let content = """
        Host myserver
            HostName example.com
            User admin
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 1)
        #expect(result[0].host == "myserver")
        #expect(result[0].hostname == "example.com")
        #expect(result[0].port == nil)
        #expect(result[0].user == "admin")
    }

    @Test("Host without user")
    func testHostWithoutUser() {
        let content = """
        Host myserver
            HostName example.com
            Port 2222
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 1)
        #expect(result[0].host == "myserver")
        #expect(result[0].hostname == "example.com")
        #expect(result[0].port == 2_222)
        #expect(result[0].user == nil)
    }

    @Test("Mixed entries with comments between")
    func testMixedEntriesWithCommentsBetween() {
        let content = """
        # Production servers
        Host prod1
            HostName prod1.example.com
            Port 22

        # Development servers
        Host dev1
            HostName dev1.example.com
            Port 2222

        # Skip wildcard
        Host *.local
            User localuser

        # Staging
        Host staging
            HostName staging.example.com
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 3)
        #expect(result[0].host == "prod1")
        #expect(result[1].host == "dev1")
        #expect(result[2].host == "staging")
    }

    @Test("Case-insensitive keys")
    func testCaseInsensitiveKeys() {
        let content = """
        Host server1
            hostname example1.com
            PORT 2222

        Host server2
            HOSTNAME example2.com
            port 3333
            USER admin
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 2)
        #expect(result[0].hostname == "example1.com")
        #expect(result[0].port == 2_222)
        #expect(result[1].hostname == "example2.com")
        #expect(result[1].port == 3_333)
        #expect(result[1].user == "admin")
    }

    @Test("Extra whitespace handling")
    func testExtraWhitespaceHandling() {
        let content = """
        Host    myserver
            HostName     example.com
                Port   2222
            User     admin
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 1)
        #expect(result[0].host == "myserver")
        #expect(result[0].hostname == "example.com")
        #expect(result[0].port == 2_222)
        #expect(result[0].user == "admin")
    }

    @Test("Display name when host differs from hostname")
    func testDisplayNameWithDifferentHostname() {
        let content = """
        Host myserver
            HostName example.com
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 1)
        #expect(result[0].displayName == "myserver (example.com)")
    }

    @Test("Display name without hostname")
    func testDisplayNameWithoutHostname() {
        let content = """
        Host myserver
            Port 2222
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 1)
        #expect(result[0].displayName == "myserver")
    }

    @Test("IdentityAgent directive is parsed with tilde expansion")
    func testIdentityAgentWithTildeExpansion() {
        let content = """
        Host myserver
            HostName example.com
            IdentityAgent ~/.1password/agent.sock
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 1)

        let homeDir = NSHomeDirectory()
        #expect(result[0].identityAgent?.contains(homeDir) == true)
        #expect(result[0].identityAgent?.contains(".1password/agent.sock") == true)
    }

    @Test("IdentityAgent with absolute path")
    func testIdentityAgentAbsolutePath() {
        let content = """
        Host myserver
            HostName example.com
            IdentityAgent /run/user/1000/ssh-agent.sock
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 1)
        #expect(result[0].identityAgent == "/run/user/1000/ssh-agent.sock")
    }

    @Test("Entry without IdentityAgent has nil")
    func testNoIdentityAgent() {
        let content = """
        Host myserver
            HostName example.com
            User admin
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 1)
        #expect(result[0].identityAgent == nil)
    }

    @Test("IdentityAgent resets between host entries")
    func testIdentityAgentResetsBetweenEntries() {
        let content = """
        Host server1
            HostName host1.com
            IdentityAgent ~/.1password/agent.sock

        Host server2
            HostName host2.com
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 2)
        #expect(result[0].identityAgent != nil)
        #expect(result[1].identityAgent == nil)
    }

    @Test("ProxyJump directive is parsed")
    func testProxyJumpParsed() {
        let content = """
        Host myserver
            HostName example.com
            ProxyJump admin@bastion.com:2222
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 1)
        #expect(result[0].proxyJump == "admin@bastion.com:2222")
    }

    @Test("ProxyJump with multiple hops")
    func testProxyJumpMultipleHops() {
        let content = """
        Host myserver
            HostName example.com
            ProxyJump user1@hop1.com,user2@hop2.com:2222
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 1)
        #expect(result[0].proxyJump == "user1@hop1.com,user2@hop2.com:2222")
    }

    @Test("ProxyJump resets between host entries")
    func testProxyJumpResetsBetweenEntries() {
        let content = """
        Host server1
            HostName host1.com
            ProxyJump admin@bastion.com

        Host server2
            HostName host2.com
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 2)
        #expect(result[0].proxyJump == "admin@bastion.com")
        #expect(result[1].proxyJump == nil)
    }

    @Test("Entry without ProxyJump has nil")
    func testNoProxyJump() {
        let content = """
        Host myserver
            HostName example.com
            User admin
        """

        let result = SSHConfigParser.parseContent(content)
        #expect(result.count == 1)
        #expect(result[0].proxyJump == nil)
    }

    @Test("parseProxyJump single hop with user and port")
    func testParseProxyJumpSingleHop() {
        let jumpHosts = SSHConfigParser.parseProxyJump("admin@bastion.com:2222")
        #expect(jumpHosts.count == 1)
        #expect(jumpHosts[0].username == "admin")
        #expect(jumpHosts[0].host == "bastion.com")
        #expect(jumpHosts[0].port == 2_222)
    }

    @Test("parseProxyJump multi-hop")
    func testParseProxyJumpMultiHop() {
        let jumpHosts = SSHConfigParser.parseProxyJump("user1@hop1.com,user2@hop2.com:2222")
        #expect(jumpHosts.count == 2)
        #expect(jumpHosts[0].username == "user1")
        #expect(jumpHosts[0].host == "hop1.com")
        #expect(jumpHosts[0].port == 22)
        #expect(jumpHosts[1].username == "user2")
        #expect(jumpHosts[1].host == "hop2.com")
        #expect(jumpHosts[1].port == 2_222)
    }

    @Test("parseProxyJump without user")
    func testParseProxyJumpWithoutUser() {
        let jumpHosts = SSHConfigParser.parseProxyJump("bastion.com:2222")
        #expect(jumpHosts.count == 1)
        #expect(jumpHosts[0].username == "")
        #expect(jumpHosts[0].host == "bastion.com")
        #expect(jumpHosts[0].port == 2_222)
    }

    @Test("parseProxyJump without port")
    func testParseProxyJumpWithoutPort() {
        let jumpHosts = SSHConfigParser.parseProxyJump("admin@bastion.com")
        #expect(jumpHosts.count == 1)
        #expect(jumpHosts[0].username == "admin")
        #expect(jumpHosts[0].host == "bastion.com")
        #expect(jumpHosts[0].port == 22)
    }

    @Test("parseProxyJump with bracketed IPv6 and port")
    func testParseProxyJumpIPv6WithPort() {
        let jumpHosts = SSHConfigParser.parseProxyJump("admin@[::1]:2222")
        #expect(jumpHosts.count == 1)
        #expect(jumpHosts[0].username == "admin")
        #expect(jumpHosts[0].host == "::1")
        #expect(jumpHosts[0].port == 2_222)
    }

    @Test("parseProxyJump with bracketed IPv6 without port")
    func testParseProxyJumpIPv6WithoutPort() {
        let jumpHosts = SSHConfigParser.parseProxyJump("admin@[fe80::1]")
        #expect(jumpHosts.count == 1)
        #expect(jumpHosts[0].username == "admin")
        #expect(jumpHosts[0].host == "fe80::1")
        #expect(jumpHosts[0].port == 22)
    }
}
