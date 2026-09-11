//
//  MCPServerConfigurationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Outside MCP server configuration")
struct MCPServerConfigurationTests {
    private func url(_ string: String) -> URL? { URL(string: string) }

    @Test("The namespace is keyed on the server id, not its name")
    func namespaceUsesTheServerId() {
        let id = UUID()
        let server = MCPServerConfiguration(
            id: id,
            name: "TablePro",
            endpoint: URL(string: "https://example.com/mcp") ?? URL(fileURLWithPath: "/")
        )

        #expect(server.toolNamespace == "ext__\(id.uuidString.lowercased())__")
        #expect(server.toolName(for: "search") == "ext__\(id.uuidString.lowercased())__search")
        #expect(!server.toolNamespace.contains("tablepro"))
    }

    @Test("A name that slugifies to TablePro's own namespace is refused")
    func reservedNamesAreRefused() {
        for name in ["TablePro", "table pro", "TABLE-PRO", " tablepro "] {
            #expect(
                MCPServerConfigurationValidator.validate(name: name, endpoint: url("https://example.com/mcp"))
                    == .reservedName
            )
        }
    }

    @Test("An empty name is refused")
    func emptyNameRefused() {
        #expect(
            MCPServerConfigurationValidator.validate(name: "   ", endpoint: url("https://example.com/mcp"))
                == .emptyName
        )
    }

    @Test("Plain http is refused off this Mac and allowed on it")
    func httpOnlyForLoopback() {
        #expect(
            MCPServerConfigurationValidator.validate(name: "docs", endpoint: url("http://example.com/mcp"))
                == .insecureEndpoint
        )
        #expect(
            MCPServerConfigurationValidator.validate(name: "docs", endpoint: url("http://127.0.0.1:9000/mcp"))
                == nil
        )
        #expect(
            MCPServerConfigurationValidator.validate(name: "docs", endpoint: url("http://localhost:9000/mcp"))
                == nil
        )
    }

    @Test("A non-HTTP scheme, or a URL with no host, is refused")
    func endpointMustBeHttp() {
        #expect(
            MCPServerConfigurationValidator.validate(name: "docs", endpoint: url("ftp://example.com/mcp"))
                == .invalidEndpoint
        )
        #expect(MCPServerConfigurationValidator.validate(name: "docs", endpoint: nil) == .invalidEndpoint)
        #expect(
            MCPServerConfigurationValidator.validate(name: "docs", endpoint: url("stdio:local"))
                == .invalidEndpoint
        )
    }

    @Test("A valid server is accepted")
    func validServerAccepted() {
        #expect(
            MCPServerConfigurationValidator.validate(name: "GitHub", endpoint: url("https://mcp.example.com"))
                == nil
        )
    }

    @Test("A server with an empty allowlist reaches no connection")
    func emptyAllowlistReachesNothing() {
        let server = MCPServerConfiguration(
            name: "docs",
            endpoint: URL(string: "https://example.com/mcp") ?? URL(fileURLWithPath: "/")
        )

        #expect(!server.allows(connectionId: UUID()))
        #expect(!server.allows(connectionId: nil))
    }

    @Test("A session with no connection reaches no server, even one that allows everything else")
    func nilConnectionReachesNothing() {
        let allowed = UUID()
        let server = MCPServerConfiguration(
            name: "docs",
            endpoint: URL(string: "https://example.com/mcp") ?? URL(fileURLWithPath: "/"),
            allowedConnectionIds: [allowed]
        )

        #expect(server.allows(connectionId: allowed))
        #expect(!server.allows(connectionId: nil))
        #expect(!server.allows(connectionId: UUID()))
    }
}
