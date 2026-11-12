import Foundation
@testable import TableProMCPClients
import Testing

struct MCPEntryUpdateTests {
    private struct Rendered {
        let entry: JSONValue
        let template: JSONValue
    }

    private func rendered(_ id: String, platform: MCPClientPlatform = .macos) throws -> Rendered {
        let spec = try #require(try MCPClientsFixtures.client(id).spec(for: platform))
        let template = try #require(spec.entry)
        return Rendered(entry: try MCPClientsFixtures.renderer(for: platform).entry(spec), template: template)
    }

    private func updatedJSON(_ id: String, _ text: String, platform: MCPClientPlatform = .macos) throws -> JSONValue? {
        let update = try rendered(id, platform: platform)
        let result = try JSONCMemberEditor.updating(
            "tablepro", entry: update.entry, template: update.template, at: ["mcpServers"], in: text
        )
        return try JSONCMemberEditor.member("tablepro", at: ["mcpServers"], in: result)
    }

    private static let old = "/Volumes/Gone/TablePro.app/Contents/MacOS/tablepro-mcp"

    @Test("Update keeps Copilot CLI's tool list and the turned-off flag of Cline and Kiro")
    func keepsRestrictions() throws {
        let copilot = try #require(try updatedJSON("copilot-cli", """
        {"mcpServers": {"tablepro": {"type": "local", "command": "\(Self.old)", "args": [], "tools": ["list_connections"]}}}
        """))
        #expect(copilot["tools"] == .array([.string("list_connections")]))
        #expect(copilot["command"] == .string(MCPClientsFixtures.bridge))

        for id in ["cline", "kiro"] {
            let entry = try #require(try updatedJSON(id, """
            {"mcpServers": {"tablepro": {"command": "\(Self.old)", "args": [], "disabled": true}}}
            """))
            #expect(entry["disabled"] == .bool(true))
            #expect(entry["command"] == .string(MCPClientsFixtures.bridge))
        }
    }

    @Test("A member the catalog sets that the entry lacks is added, and type and args are always rewritten")
    func fillsMissingMembers() throws {
        let copilot = try #require(try updatedJSON("copilot-cli", """
        {"mcpServers": {"tablepro": {"type": "stdio", "command": "\(Self.old)", "args": ["--old"]}}}
        """))
        #expect(copilot == .object([
            (key: "type", value: .string("local")),
            (key: "command", value: .string(MCPClientsFixtures.bridge)),
            (key: "args", value: .array([])),
            (key: "tools", value: .array([.string("*")])),
        ]))
    }

    @Test("A placeholder at any depth is rewritten, and the user's own headers and keys stay")
    func rewritesNestedConnectionMembers() throws {
        let entry = try #require(try updatedJSON("cline", """
        {"mcpServers": {"tablepro": {"type": "sse", "url": "http://127.0.0.1:1/mcp", "timeout": 5, "disabled": true,
          "headers": {"Authorization": "Bearer tp_old", "X-Trace": "1"}}}}
        """, platform: .linux))
        #expect(entry["type"] == .string("streamableHttp"))
        #expect(entry["url"] == .string(MCPClientsFixtures.httpURL))
        #expect(entry["headers"] == .object([
            (key: "Authorization", value: .string(MCPClientsFixtures.authorization)),
            (key: "X-Trace", value: .string("1")),
        ]))
        #expect(entry["timeout"] == .number(5))
        #expect(entry["disabled"] == .bool(true))
    }

    @Test("An entry that reaches TablePro the other way is replaced whole, keeping only the user's choices")
    func transportChangeReplacesTheEntry() throws {
        let toHTTP = try updatedJSON("cursor", """
        {"mcpServers": {"tablepro": {"command": "/x", "args": [], "env": {"A": "1"}}}}
        """, platform: .linux)
        #expect(toHTTP == (try rendered("cursor", platform: .linux).entry))

        let toStdio = try updatedJSON("cline", """
        {"mcpServers": {"tablepro": {"url": "http://127.0.0.1:23508/mcp", "headers": {"Authorization": "Bearer tp_x"}}}}
        """)
        #expect(toStdio == (try rendered("cline").entry))

        let copilot = try updatedJSON("copilot-cli", """
        {"mcpServers": {"tablepro": {"type": "local", "command": "/x", "args": [], "env": {"A": "1"}, "tools": ["list_connections"]}}}
        """, platform: .linux)
        #expect(copilot == .object([
            (key: "type", value: .string("http")),
            (key: "url", value: .string(MCPClientsFixtures.httpURL)),
            (key: "headers", value: .object([(key: "Authorization", value: .string(MCPClientsFixtures.authorization))])),
            (key: "tools", value: .array([.string("list_connections")])),
        ]))
    }

    @Test("A missing entry is added as rendered, and an unchanged one is left byte for byte")
    func addsAndLeavesAlone() throws {
        let update = try rendered("copilot-cli")
        let empty = #"{"mcpServers": {}}"#
        let added = try JSONCMemberEditor.updating("tablepro", entry: update.entry, template: update.template, at: ["mcpServers"], in: empty)
        #expect(try JSONCMemberEditor.member("tablepro", at: ["mcpServers"], in: added) == update.entry)
        #expect(try JSONCMemberEditor.updating("tablepro", entry: update.entry, template: update.template, at: ["mcpServers"], in: added)
            == added)

        let current = """
        {"mcpServers": {"tablepro": {"type": "local", "command": "\(MCPClientsFixtures.bridge)", "args": [], "tools": ["a"],
          "timeout": 1.0}}}
        """
        #expect(try JSONCMemberEditor.updating("tablepro", entry: update.entry, template: update.template, at: ["mcpServers"], in: current)
            == current)
    }

    @Test("Codex's TOML table keeps a key the catalog only fills in, and its own headers")
    func tomlKeepsRestrictions() throws {
        let template: JSONValue = .object([
            (key: "command", value: .string("{command}")),
            (key: "args", value: .array([])),
            (key: "enabled", value: .bool(true)),
        ])
        let entry = try MCPClientsFixtures.renderer(for: .macos).entry(template: template)
        let text = "[mcp_servers.tablepro]\ncommand = \"\(Self.old)\"\nargs = []\nenabled = false\n"
        let updated = try TOMLTableEditor.updating("tablepro", entry: entry, template: template, at: ["mcp_servers"], in: text)
        #expect(updated == "[mcp_servers.tablepro]\ncommand = \"\(MCPClientsFixtures.bridge)\"\nargs = []\nenabled = false\n")

        let http = try rendered("codex", platform: .linux)
        let table = """
        [mcp_servers.tablepro]
        url = "http://127.0.0.1:1/mcp"
        http_headers = { Authorization = "Bearer tp_old", X-Trace = "1" }
        startup_timeout_sec = 30

        """
        let merged = try TOMLTableEditor.updating("tablepro", entry: http.entry, template: http.template, at: ["mcp_servers"], in: table)
        #expect(merged == """
        [mcp_servers.tablepro]
        url = "\(MCPClientsFixtures.httpURL)"
        http_headers = { Authorization = "\(MCPClientsFixtures.authorization)", X-Trace = "1" }
        startup_timeout_sec = 30

        """)
    }

    @Test("A TOML table that reaches TablePro the other way is replaced with its subtables")
    func tomlTransportChangeReplacesTheTable() throws {
        let http = try rendered("codex", platform: .linux)
        let text = "[mcp_servers.tablepro]\ncommand = \"/x\"\n\n[mcp_servers.tablepro.env]\nA = \"1\"\n"
        let replaced = try TOMLTableEditor.updating("tablepro", entry: http.entry, template: http.template, at: ["mcp_servers"], in: text)
        #expect(try TOMLTableEditor.member("tablepro", at: ["mcp_servers"], in: replaced) == http.entry)
    }
}
