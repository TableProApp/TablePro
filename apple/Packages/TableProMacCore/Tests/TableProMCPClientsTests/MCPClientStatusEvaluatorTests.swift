import Foundation
@testable import TableProMCPClients
import Testing

struct MCPClientStatusEvaluatorTests {
    private let json = MCPConfigLocation(path: "~/.cursor/mcp.json", format: .json, keyPath: ["mcpServers"])
    private let stdio = MCPServerTarget.stdio(command: MCPClientsFixtures.bridge)
    private let http = MCPServerTarget.http(url: MCPClientsFixtures.httpURL, authorization: MCPClientsFixtures.authorization)

    private func status(
        _ text: String?,
        location: MCPConfigLocation?,
        expected: MCPServerTarget,
        existing: Set<String> = []
    ) -> MCPClientConfigStatus {
        MCPClientStatusEvaluator.status(
            configText: text, location: location, serverName: "tablepro", expected: expected, fileExists: { existing.contains($0) }
        )
    }

    @Test("No config location is unknown; no file is not configured")
    func missingInputs() {
        #expect(status("{}", location: nil, expected: stdio) == .unknown)
        #expect(status(nil, location: json, expected: stdio) == .notConfigured)
        #expect(status("", location: json, expected: stdio) == .notConfigured)
        #expect(status(#"{"mcpServers": {"other": {}}}"#, location: json, expected: stdio) == .notConfigured)
    }

    @Test("The running bridge's path is current")
    func stdioCurrent() {
        let text = "{\n  // c\n  \"mcpServers\": {\"tablepro\": {\"command\": \"\(MCPClientsFixtures.bridge)\", \"args\": []},}\n}"
        #expect(status(text, location: json, expected: stdio) == .current)
    }

    @Test("An array command is compared by its first element")
    func arrayCommand() throws {
        let location = try MCPClientsFixtures.location("opencode")
        let text = #"{"mcp": {"servers": {"tablepro": {"type": "local", "command": ["\#(MCPClientsFixtures.bridge)", "--x"]}}}}"#
        #expect(status(text, location: location, expected: stdio) == .current)
    }

    @Test("A command that is gone is stale as missing; another existing one as another command")
    func stdioStale() {
        let text = #"{"mcpServers": {"tablepro": {"command": "\#(MCPClientsFixtures.betaBridge)"}}}"#
        #expect(status(text, location: json, expected: stdio) == .stale(.commandMissing))
        #expect(status(text, location: json, expected: stdio, existing: [MCPClientsFixtures.betaBridge]) == .stale(.otherCommand))
        #expect(status(#"{"mcpServers": {"tablepro": {"type": "stdio"}}}"#, location: json, expected: stdio) == .stale(.otherCommand))
    }

    @Test("An HTTP entry where the bridge is expected is set up with a token, never stale")
    func httpEntryUsesToken() throws {
        let tokenSheet = #"{"mcpServers": {"tablepro": {"url": "http://127.0.0.1:23508/mcp", "headers": {"Authorization": "Bearer tp_x"}}}}"#
        #expect(status(tokenSheet, location: json, expected: stdio) == .usesToken)
        let claudeCode = try MCPClientsFixtures.location("claude-code")
        let added = #"{"mcpServers": {"tablepro": {"type": "http", "url": "http://localhost:23508/mcp", "headers": {"Authorization": "Bearer tp_x"}}}}"#
        #expect(status(added, location: claudeCode, expected: stdio) == .usesToken)
        let codex = try MCPClientsFixtures.location("codex")
        let table = "[mcp_servers.tablepro]\nurl = \"http://127.0.0.1:23508/mcp\"\nhttp_headers = { Authorization = \"Bearer tp_x\" }\n"
        #expect(status(table, location: codex, expected: stdio) == .usesToken)
    }

    @Test("A current entry the user turned off reads as disabled")
    func disabledEntries() throws {
        func entry(_ fields: String) -> String {
            #"{"mcpServers": {"tablepro": {"command": "\#(MCPClientsFixtures.bridge)", \#(fields)}}}"#
        }
        #expect(status(entry(#""disabled": true"#), location: json, expected: stdio) == .disabled)
        #expect(status(entry(#""enabled": false"#), location: json, expected: stdio) == .disabled)
        #expect(status(entry(#""disabled": false"#), location: json, expected: stdio) == .current)
        #expect(status(entry(#""enabled": true"#), location: json, expected: stdio) == .current)

        let codex = try MCPClientsFixtures.location("codex")
        let table = "[mcp_servers.tablepro]\ncommand = \"\(MCPClientsFixtures.bridge)\"\nenabled = false\n"
        #expect(status(table, location: codex, expected: stdio) == .disabled)
    }

    @Test("A turned-off entry reads as disabled whatever it points at, so it is never offered an Update")
    func disabledBeforeStale() throws {
        let moved = #"{"mcpServers": {"tablepro": {"command": "/gone", "disabled": true}}}"#
        #expect(status(moved, location: json, expected: stdio) == .disabled)
        let token = #"{"mcpServers": {"tablepro": {"url": "http://127.0.0.1:23508/mcp", "enabled": false}}}"#
        #expect(status(token, location: json, expected: stdio) == .disabled)
        let codex = try MCPClientsFixtures.location("codex")
        let oldToken = "[mcp_servers.tablepro]\nurl = \"\(MCPClientsFixtures.httpURL)\"\n"
            + "http_headers = { Authorization = \"Bearer tp_old\" }\nenabled = false\n"
        #expect(status(oldToken, location: codex, expected: http) == .disabled)
    }

    @Test("A hit only in another scope is otherScope, with * matching any key")
    func otherScopes() throws {
        let claudeCode = try MCPClientsFixtures.location("claude-code")
        let local = #"{"projects": {"/Users/me/app": {"mcpServers": {"tablepro": {"command": "/b"}}}}, "mcpServers": {}}"#
        #expect(status(local, location: claudeCode, expected: stdio, existing: ["/Users/me/app"]) == .otherScope)
        let bridge = MCPClientsFixtures.bridge
        let both = #"{"projects": {"/x": {"mcpServers": {"tablepro": {"command": "\#(bridge)"}}}}, "mcpServers": {"tablepro": {"command": "\#(bridge)"}}}"#
        #expect(status(both, location: claudeCode, expected: stdio, existing: ["/x"]) == .current)
        #expect(status(#"{"projects": {"/x": {"mcpServers": {}}, "/y": []}}"#, location: claudeCode, expected: stdio) == .notConfigured)
    }

    @Test("A project whose folder is gone is not a scope any more")
    func goneProjectFolders() throws {
        let claudeCode = try MCPClientsFixtures.location("claude-code")
        let onlyThere = #"{"projects": {"/Users/me/old": {"mcpServers": {"tablepro": {"command": "/b"}}}}, "mcpServers": {}}"#
        #expect(status(onlyThere, location: claudeCode, expected: stdio) == .notConfigured)
        let bridge = MCPClientsFixtures.bridge
        let shadowedByGone = #"{"projects": {"/Users/me/old": {"mcpServers": {"tablepro": {"command": "/Volumes/Gone/tablepro-mcp"}}}}, "#
            + #""mcpServers": {"tablepro": {"command": "\#(bridge)"}}}"#
        #expect(status(shadowedByGone, location: claudeCode, expected: stdio) == .current)
        #expect(status(shadowedByGone, location: claudeCode, expected: stdio, existing: ["/Users/me/old"])
            == .stale(.shadowed(scope: "/Users/me/old")))
    }

    @Test("A stale entry in another scope shadows a current one there and names it; a token or turned-off one does not")
    func shadowingScopes() throws {
        let claudeCode = try MCPClientsFixtures.location("claude-code")
        func file(project: String) -> String {
            #"{"projects": {"/a": {"mcpServers": {}}, "/b": {"mcpServers": {"tablepro": \#(project)}}}, "#
                + #""mcpServers": {"tablepro": {"type": "stdio", "command": "\#(MCPClientsFixtures.bridge)"}}}"#
        }
        let folders: Set<String> = ["/a", "/b"]
        #expect(status(file(project: #"{"command": "/Volumes/Gone/tablepro-mcp"}"#), location: claudeCode, expected: stdio, existing: folders)
            == .stale(.shadowed(scope: "/b")))
        #expect(status(file(project: #"{"command": "/x"}"#), location: claudeCode, expected: stdio, existing: folders.union(["/x"]))
            == .stale(.shadowed(scope: "/b")))
        let token = #"{"type": "http", "url": "http://127.0.0.1:23508/mcp", "headers": {"Authorization": "Bearer tp_x"}}"#
        #expect(status(file(project: token), location: claudeCode, expected: stdio, existing: folders) == .current)
        let off = #"{"command": "/Volumes/Gone/tablepro-mcp", "disabled": true}"#
        #expect(status(file(project: off), location: claudeCode, expected: stdio, existing: folders) == .current)

        let staleUser = #"{"projects": {"/b": {"mcpServers": {"tablepro": {"command": "/x"}}}}, "mcpServers": {"tablepro": {"command": "/y"}}}"#
        #expect(status(staleUser, location: claudeCode, expected: stdio, existing: folders) == .stale(.commandMissing))
    }

    @Test("opencode's V1 mcp.<name> reads like its V2 mcp.servers.<name>, never as another scope")
    func alternateKeyPaths() throws {
        let opencode = try MCPClientsFixtures.location("opencode")
        let bridge = MCPClientsFixtures.bridge
        #expect(status(#"{"mcp": {"tablepro": {"type": "local", "command": ["\#(bridge)"]}}}"#, location: opencode, expected: stdio) == .current)
        #expect(status(#"{"mcp": {"tablepro": {"type": "local", "command": ["/gone"]}}}"#, location: opencode, expected: stdio)
            == .stale(.commandMissing))
        #expect(status(#"{"mcp": {"servers": {"tablepro": {"command": ["\#(bridge)"]}}}}"#, location: opencode, expected: stdio) == .current)
        #expect(status(#"{"mcp": {"servers": {}, "other": {}}}"#, location: opencode, expected: stdio) == .notConfigured)
        #expect(status(#"{"mcp": {"tablepro": {"type": "local"}}}"#, location: opencode, expected: stdio) == .stale(.otherCommand))
    }

    @Test("An unpaired surrogate escape, which Node writes, does not make a file unreadable")
    func loneSurrogate() {
        let escape = "\\" + "ud83d"
        let text = #"{"title": ""# + escape + #"", "mcpServers": {"tablepro": {"command": "\#(MCPClientsFixtures.bridge)"}}}"#
        #expect(status(text, location: json, expected: stdio) == .current)
    }

    @Test("Text that cannot be read safely is unreadable")
    func unreadable() {
        #expect(status("{", location: json, expected: stdio) == .unreadable)
        #expect(status(#"{"mcpServers": {}, "mcpServers": {}}"#, location: json, expected: stdio) == .unreadable)
        #expect(status(#"{"mcpServers": []}"#, location: json, expected: stdio) == .unreadable)
        let toml = MCPConfigLocation(path: "~/.codex/config.toml", format: .toml, keyPath: ["mcp_servers"])
        #expect(status("[mcp_servers]\ntablepro.command = \"x\"\n", location: toml, expected: stdio) == .unreadable)
    }

    @Test("A YAML config is unknown")
    func yaml() {
        let location = MCPConfigLocation(path: "~/.config/goose/config.yaml", format: .yaml, keyPath: ["extensions"], isWritable: false)
        #expect(status("extensions: {}\n", location: location, expected: stdio) == .unknown)
        #expect(status(nil, location: location, expected: stdio) == .unknown)
    }

    @Test("Codex's TOML table is compared like JSON")
    func toml() throws {
        let location = try MCPClientsFixtures.location("codex")
        #expect(status("[mcp_servers.tablepro]\ncommand = \"\(MCPClientsFixtures.bridge)\"\n", location: location, expected: stdio) == .current)
        #expect(status("[mcp_servers.tablepro]\ncommand = \"/gone\"\n", location: location, expected: stdio) == .stale(.commandMissing))
        #expect(status("[mcp_servers.other]\ncommand = \"/o\"\n", location: location, expected: stdio) == .notConfigured)

        let httpTable = """
        [mcp_servers.tablepro]
        url = "\(MCPClientsFixtures.httpURL)"
        http_headers = { Authorization = "\(MCPClientsFixtures.authorization)" }
        """
        #expect(status(httpTable, location: location, expected: http) == .current)
        #expect(status(httpTable.replacingOccurrences(of: "tp_test", with: "tp_old"), location: location, expected: http) == .stale(.otherToken))
        #expect(status(httpTable.replacingOccurrences(of: "23508", with: "23509"), location: location, expected: http) == .stale(.otherURL))
    }

    @Test("HTTP entries compare the endpoint and the Authorization header, whatever the key names; a command entry is another command")
    func httpEntries() {
        func entry(_ fields: String) -> String {
            #"{"mcpServers": {"tablepro": {\#(fields)}}}"#
        }
        let headers = #""headers": {"authorization": "Bearer tp_test"}"#
        #expect(status(entry(#""url": "http://127.0.0.1:23508/mcp", \#(headers)"#), location: json, expected: http) == .current)
        #expect(status(entry(#""serverUrl": "http://localhost:23508/mcp/", \#(headers)"#), location: json, expected: http) == .current)
        #expect(status(entry(#""httpUrl": "http://127.0.0.1:23508/mcp", \#(headers)"#), location: json, expected: http) == .current)
        #expect(status(entry(#""url": "https://127.0.0.1:23508/mcp", \#(headers)"#), location: json, expected: http) == .stale(.otherURL))
        #expect(status(entry(#""url": "http://example.com:23508/mcp", \#(headers)"#), location: json, expected: http) == .stale(.otherURL))
        #expect(status(entry(#""command": "/b""#), location: json, expected: http) == .stale(.otherCommand))
        #expect(status(entry(#""type": "http""#), location: json, expected: http) == .stale(.otherURL))
        #expect(status(entry(#""url": "http://127.0.0.1:23508/mcp""#), location: json, expected: http) == .stale(.otherToken))
        #expect(status(entry(#""url": "http://127.0.0.1:23508/mcp", "headers": {"Authorization": "Bearer other"}"#), location: json, expected: http)
            == .stale(.otherToken))
    }
}
