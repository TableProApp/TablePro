//
//  SSHUnsupportedDirectiveTests.swift
//  TableProTests
//
//  A ProxyCommand host connects through a command TablePro cannot run, so TablePro dials the
//  hostname directly and reaches a different place than ssh would. That was dropped without a
//  word, which leaves a "works in Terminal, fails here" report with nothing to go on.
//

@testable import TablePro
import Testing

@Suite("SSHUnsupportedDirective")
struct SSHUnsupportedDirectiveTests {
    @Test("ProxyCommand is reported")
    func proxyCommandChangesRouting() {
        #expect(SSHUnsupportedDirective.changesRouting(key: "ProxyCommand"))
    }

    @Test("The match ignores case, the way ssh_config keywords do")
    func matchIsCaseInsensitive() {
        #expect(SSHUnsupportedDirective.changesRouting(key: "proxycommand"))
        #expect(SSHUnsupportedDirective.changesRouting(key: "PROXYCOMMAND"))
    }

    @Test("ProxyUseFdpass is reported")
    func proxyUseFdpassChangesRouting() {
        #expect(SSHUnsupportedDirective.changesRouting(key: "ProxyUseFdpass"))
    }

    @Test("Directives TablePro honours are not reported")
    func supportedDirectivesAreNotReported() {
        #expect(!SSHUnsupportedDirective.changesRouting(key: "ProxyJump"))
        #expect(!SSHUnsupportedDirective.changesRouting(key: "HostName"))
        #expect(!SSHUnsupportedDirective.changesRouting(key: "IdentityFile"))
    }

    @Test("Directives that do not change where the connection lands stay quiet")
    func harmlessDirectivesAreNotReported() {
        #expect(!SSHUnsupportedDirective.changesRouting(key: "Compression"))
        #expect(!SSHUnsupportedDirective.changesRouting(key: "ServerAliveInterval"))
        #expect(!SSHUnsupportedDirective.changesRouting(key: "StrictHostKeyChecking"))
        #expect(!SSHUnsupportedDirective.changesRouting(key: ""))
    }
}

@Suite("ProxyCommand parsing")
struct SSHProxyCommandParsingTests {
    @Test("ProxyCommand parses as an unrecognized directive so it can be reported")
    func proxyCommandIsUnrecognized() {
        let document = SSHConfigParser.parseDocumentContent(
            """
            Host bastioned
                HostName db.internal
                ProxyCommand ssh -W %h:%p bastion.example.com
            """
        )

        let directives = document.blocks.flatMap(\.directives)
        let unrecognized = directives.compactMap { directive -> String? in
            guard case .unrecognized(let key, _) = directive else { return nil }
            return key
        }

        #expect(unrecognized.contains("ProxyCommand"))
        #expect(unrecognized.allSatisfy { SSHUnsupportedDirective.changesRouting(key: $0) })
    }

    @Test("ProxyJump stays a first-class directive and is not reported as unsupported")
    func proxyJumpIsRecognized() {
        let document = SSHConfigParser.parseDocumentContent(
            """
            Host bastioned
                HostName db.internal
                ProxyJump bastion.example.com
            """
        )

        let directives = document.blocks.flatMap(\.directives)
        #expect(directives.contains { directive in
            guard case .proxyJump(let value) = directive else { return false }
            return value == "bastion.example.com"
        })
        #expect(!directives.contains { directive in
            guard case .unrecognized = directive else { return false }
            return true
        })
    }
}
