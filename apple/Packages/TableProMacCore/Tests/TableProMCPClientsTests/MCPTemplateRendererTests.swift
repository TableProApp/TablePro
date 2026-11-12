import Foundation
@testable import TableProMCPClients
import Testing

struct MCPTemplateRendererTests {
    private let stdio = MCPTemplateRenderer(serverName: "tablepro", target: .stdio(command: MCPClientsFixtures.betaBridge))

    @Test("Cursor's config is base64 of the compact entry, percent-encoded")
    func cursorDeeplink() throws {
        let spec = try #require(try MCPClientsFixtures.catalog().client(id: "cursor")?.spec(for: .macos))
        guard case let .deeplink(_, template)? = spec.install.first else {
            Issue.record("Cursor installs through a deeplink first")
            return
        }
        let entry = try stdio.entry(spec)
        #expect(entry.compactText == #"{"type":"stdio","command":"/Applications/TablePro Beta.app/Contents/MacOS/tablepro-mcp","args":[]}"#)
        let url = try stdio.url(template, entry: entry)
        #expect(url.absoluteString == "cursor://anysphere.cursor-deeplink/mcp/install?name=tablepro&config="
            + "eyJ0eXBlIjoic3RkaW8iLCJjb21tYW5kIjoiL0FwcGxpY2F0aW9ucy9UYWJsZVBybyBCZXRhLmFwcC9Db250ZW50cy9NYWNPUy90YWJsZXByby1tY3AiLCJhcmdzIjpbXX0%3D")

        let config = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "config" }?.value)
        let decoded = try #require(Data(base64Encoded: config))
        #expect(String(bytes: decoded, encoding: .utf8) == entry.compactText)
    }

    @Test("VS Code gets the percent-encoded entry with name first")
    func vscodeDeeplink() throws {
        let spec = try #require(try MCPClientsFixtures.catalog().client(id: "vscode")?.spec(for: .macos))
        guard case let .deeplink(scheme, template)? = spec.install.first else {
            Issue.record("VS Code installs through a deeplink first")
            return
        }
        let renderer = MCPClientsFixtures.renderer(for: .macos)
        let url = try renderer.url(template, entry: try renderer.entry(spec))
        #expect(scheme == "vscode")
        #expect(url.absoluteString == "vscode:mcp/install?"
            + "%7B%22name%22%3A%22tablepro%22%2C%22type%22%3A%22stdio%22%2C%22command%22%3A%22%2FApplications%2FTablePro.app"
            + "%2FContents%2FMacOS%2Ftablepro-mcp%22%2C%22args%22%3A%5B%5D%7D")
    }

    @Test("entryWithName replaces a name the entry already has")
    func entryWithNameReplacesName() throws {
        let entry: JSONValue = .object([(key: "type", value: .string("stdio")), (key: "name", value: .string("old"))])
        let url = try stdio.url("x:{entryWithName|json|uri}", entry: entry)
        #expect(url.absoluteString == "x:%7B%22name%22%3A%22tablepro%22%2C%22type%22%3A%22stdio%22%7D")
    }

    @Test("Goose's deeplink percent-encodes the bridge path")
    func gooseDeeplink() throws {
        let spec = try #require(try MCPClientsFixtures.catalog().client(id: "goose")?.spec(for: .macos))
        guard case let .deeplink(_, template)? = spec.install.first else {
            Issue.record("Goose installs through a deeplink")
            return
        }
        let url = try stdio.url(template, entry: try stdio.entry(spec))
        #expect(url.absoluteString == "goose://extension?cmd=%2FApplications%2FTablePro%20Beta.app%2FContents%2FMacOS%2Ftablepro-mcp"
            + "&id=tablepro&name=TablePro&description=TablePro%20databases")
    }

    @Test("CLI arguments substitute every placeholder in place")
    func cliArguments() throws {
        let catalog = try MCPClientsFixtures.catalog()
        let client = try #require(catalog.client(id: "claude-code"))
        for (platform, expected) in [
            (MCPClientPlatform.macos, ["mcp", "add", "--scope", "user", "tablepro", "--", MCPClientsFixtures.bridge]),
            (.linux, ["mcp", "add", "--scope", "user", "--transport", "http", "tablepro", MCPClientsFixtures.httpURL,
                      "--header", "Authorization: Bearer tp_test"]),
        ] {
            let spec = try #require(client.spec(for: platform))
            guard case .cli(let cli)? = spec.install.first else {
                Issue.record("claude-code installs through its CLI on \(platform)")
                continue
            }
            let renderer = MCPClientsFixtures.renderer(for: platform)
            #expect(try renderer.arguments(cli.add, entry: try renderer.entry(spec)) == expected)
        }
    }

    @Test("Command lines quote only the words that need it")
    func commandLineQuoting() {
        let line = stdio.commandLine(binary: "claude", arguments: ["mcp", "add", "--scope", "user", "tablepro", "--", MCPClientsFixtures.betaBridge])
        #expect(line == "claude mcp add --scope user tablepro -- '/Applications/TablePro Beta.app/Contents/MacOS/tablepro-mcp'")
        #expect(stdio.commandLine(binary: "x", arguments: ["it's", "", "a=b,c:d@e%f+g", "Authorization: Bearer t", "~/x", "$HOME"])
            == #"x 'it'\''s' '' a=b,c:d@e%f+g 'Authorization: Bearer t' '~/x' '$HOME'"#)
    }

    @Test("Entries keep numbers as integers and booleans as booleans")
    func scalarRendering() throws {
        let spec = try #require(try MCPClientsFixtures.catalog().client(id: "goose")?.spec(for: .macos))
        let entry = try stdio.entry(spec)
        #expect(entry.compactText.contains(#""enabled":true"#))
        #expect(entry.compactText.contains(#""timeout":300"#))
        #expect(entry["cmd"] == .string(MCPClientsFixtures.betaBridge))
    }

    @Test("A placeholder the target cannot fill throws")
    func unavailablePlaceholder() {
        let http = MCPTemplateRenderer(serverName: "tablepro", target: .http(url: "u", authorization: "a"))
        #expect(throws: MCPTemplateError.unavailablePlaceholder("command")) {
            try http.entry(template: .object([(key: "command", value: .string("{command}"))]))
        }
        #expect(throws: MCPTemplateError.unavailablePlaceholder("url")) {
            try stdio.arguments(["{url}"], entry: .null)
        }
        #expect(throws: MCPTemplateError.unknownPlaceholder("bridge")) {
            try stdio.arguments(["{bridge}"], entry: .null)
        }
        #expect(throws: MCPTemplateError.unknownFilter("hex")) {
            try stdio.arguments(["{name|hex}"], entry: .null)
        }
        #expect(throws: MCPTemplateError.unknownFilter("base64")) {
            try stdio.arguments(["{entry|base64}"], entry: .null)
        }
    }

    @Test("A spec without an entry throws")
    func missingEntry() throws {
        let spec = try #require(try MCPClientsFixtures.catalog().client(id: "chatgpt-classic")?.spec(for: .macos))
        #expect(throws: MCPTemplateError.missingEntry) {
            try stdio.entry(spec)
        }
    }

    @Test("The JSON snippet nests the entry under the key path, two-space indented")
    func jsonSnippet() {
        let location = MCPConfigLocation(path: "~/.cursor/mcp.json", format: .json, keyPath: ["mcpServers"])
        #expect(stdio.snippet(for: location, entry: MCPClientsFixtures.stdioEntry) == """
        {
          "mcpServers": {
            "tablepro": {
              "command": "/Applications/TablePro.app/Contents/MacOS/tablepro-mcp",
              "args": []
            }
          }
        }
        """)
        #expect(stdio.snippet(for: nil, entry: .object([(key: "command", value: .string("/b"))])) == """
        {
          "tablepro": {
            "command": "/b"
          }
        }
        """)
    }

    @Test("The TOML snippet is the server's table")
    func tomlSnippet() {
        let location = MCPConfigLocation(path: "~/.codex/config.toml", format: .toml, keyPath: ["mcp_servers"])
        let entry: JSONValue = .object([
            (key: "url", value: .string("http://127.0.0.1:23508/mcp")),
            (key: "http_headers", value: .object([(key: "Authorization", value: .string("Bearer t"))])),
        ])
        #expect(stdio.snippet(for: location, entry: entry) == """
        [mcp_servers.tablepro]
        url = "http://127.0.0.1:23508/mcp"
        http_headers = { Authorization = "Bearer t" }
        """)
    }

    @Test("The YAML snippet nests block mappings and quotes strings")
    func yamlSnippet() {
        let location = MCPConfigLocation(path: "~/.config/goose/config.yaml", format: .yaml, keyPath: ["extensions"], isWritable: false)
        let entry: JSONValue = .object([
            (key: "cmd", value: .string("/b c")),
            (key: "args", value: .array([])),
            (key: "tools", value: .array([.string("*")])),
            (key: "timeout", value: .number(300)),
        ])
        #expect(stdio.snippet(for: location, entry: entry) == """
        extensions:
          tablepro:
            cmd: "/b c"
            args: []
            tools:
              - "*"
            timeout: 300
        """)
    }
}
