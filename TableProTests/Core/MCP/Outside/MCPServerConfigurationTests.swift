//
//  MCPServerConfigurationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct MCPServerConfigurationTests {
    private func url(_ string: String) -> URL? { URL(string: string) }

    private func endpoint(_ string: String) -> URL {
        URL(string: string) ?? URL(fileURLWithPath: "/")
    }

    @Test("A name is required")
    func emptyNameIsRefused() {
        #expect(
            MCPServerConfigurationValidator.validate(name: "  ", endpoint: url("https://example.com/mcp"))
                == .emptyName
        )
    }

    /// `ClaudeAgentProvider` launches the CLI with `--allowedTools mcp__tablepro__*`, so a server
    /// the user names "TablePro" would land inside a pre-approved wildcard.
    @Test("A name that slugifies to TablePro's own namespace is refused")
    func reservedNamesAreRefused() {
        for name in ["TablePro", "table pro", "Table-Pro", "table_pro"] {
            #expect(
                MCPServerConfigurationValidator.validate(name: name, endpoint: url("https://example.com/mcp"))
                    == .reservedName,
                "\(name) should be reserved"
            )
        }
    }

    @Test("A non-HTTP address is refused")
    func nonHttpEndpointIsRefused() {
        #expect(
            MCPServerConfigurationValidator.validate(name: "Runbooks", endpoint: url("ftp://example.com"))
                == .invalidEndpoint
        )
        #expect(MCPServerConfigurationValidator.validate(name: "Runbooks", endpoint: nil) == .invalidEndpoint)
    }

    /// Plain HTTP to another machine puts the schema and the results the assistant hands the server
    /// on the wire in the clear.
    @Test("Plain HTTP is refused off this machine and allowed on it")
    func plainHttpIsLoopbackOnly() {
        #expect(
            MCPServerConfigurationValidator.validate(name: "Runbooks", endpoint: url("http://example.com/mcp"))
                == .insecureEndpoint
        )
        for host in ["http://localhost:9000/mcp", "http://127.0.0.1:9000/mcp", "http://[::1]:9000/mcp"] {
            #expect(
                MCPServerConfigurationValidator.validate(name: "Runbooks", endpoint: url(host)) == nil,
                "\(host) should be allowed"
            )
        }
    }

    /// `https://user:secret@host/mcp` would put a password in the configuration file, draw it in the
    /// settings list and hand it back to the sheet's Address field.
    @Test("An address carrying a credential is refused")
    func userinfoIsRefused() {
        for address in [
            "https://svc:s3cret@mcp.example/mcp",
            "https://svc@mcp.example/mcp",
            "http://svc:s3cret@localhost:9000/mcp"
        ] {
            #expect(
                MCPServerConfigurationValidator.validate(name: "Runbooks", endpoint: url(address))
                    == .credentialsInEndpoint,
                "\(address) should be refused"
            )
        }
    }

    @Test("HTTPS anywhere is allowed")
    func httpsIsAllowed() {
        #expect(
            MCPServerConfigurationValidator.validate(name: "Runbooks", endpoint: url("https://example.com/mcp"))
                == nil
        )
    }

    /// The namespace is keyed on the id rather than the name, so two servers the user gave the same
    /// name still own separate tools and neither can be renamed into the other's.
    @Test("Two servers never share a tool namespace")
    func namespacesAreKeyedOnTheId() {
        let first = MCPServerConfiguration(name: "Runbooks", endpoint: endpoint("https://a.example/mcp"))
        let second = MCPServerConfiguration(name: "Runbooks", endpoint: endpoint("https://b.example/mcp"))

        #expect(first.toolNamespace != second.toolNamespace)
        #expect(first.toolName(for: "search") != second.toolName(for: "search"))
        #expect(first.toolName(for: "search").hasPrefix("ext__"))
    }

    /// A server added and not yet allowed anywhere is inert, which is the safe reading of a
    /// half-finished setup.
    @Test("A server with an empty allowlist allows nothing")
    func emptyAllowlistAllowsNothing() {
        let server = MCPServerConfiguration(name: "Runbooks", endpoint: endpoint("https://a.example/mcp"))

        #expect(!server.allows(connectionId: UUID()))
        #expect(!server.allows(connectionId: nil))
    }

    @Test("A session with no connection reaches no server")
    func nilConnectionReachesNothing() {
        let connectionId = UUID()
        let server = MCPServerConfiguration(
            name: "Runbooks",
            endpoint: endpoint("https://a.example/mcp"),
            allowedConnectionIds: [connectionId]
        )

        #expect(server.allows(connectionId: connectionId))
        #expect(!server.allows(connectionId: nil))
        #expect(!server.allows(connectionId: UUID()))
    }
}
