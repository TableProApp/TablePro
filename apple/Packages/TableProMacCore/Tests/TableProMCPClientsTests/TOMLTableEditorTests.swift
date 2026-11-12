import Foundation
@testable import TableProMCPClients
import Testing

struct TOMLTableEditorTests {
    private let entry: JSONValue = .object([(key: "command", value: .string("/b"))])

    private let codexConfig = """
    # Codex settings
    model = "gpt-5"
    approval_policy = "on-request"

    [mcp_servers.node_repl]
    command = "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl" # keep this
    args = []

    [profiles.fast]
    model = "gpt-5-mini"

    """

    @Test("A missing server is appended after a blank line, and removing it restores the file")
    func appendAndRemove() throws {
        let result = try TOMLTableEditor.upserting("tablepro", value: MCPClientsFixtures.stdioEntry, at: ["mcp_servers"], in: codexConfig)
        #expect(result == codexConfig + """

        [mcp_servers.tablepro]
        command = "/Applications/TablePro.app/Contents/MacOS/tablepro-mcp"
        args = []

        """)
        #expect(try TOMLTableEditor.member("tablepro", at: ["mcp_servers"], in: result) == MCPClientsFixtures.stdioEntry)
        #expect(try TOMLTableEditor.removing("tablepro", at: ["mcp_servers"], in: result) == codexConfig)
    }

    @Test("An existing table and its subtables are replaced in place; other bytes stay")
    func replaceInPlace() throws {
        let text = """
        model = "gpt-5"

        [mcp_servers.tablepro]
        command = "/old" # old
        args = ["--x"]
        enabled = false

        [mcp_servers.tablepro.env]
        TOKEN = "x"

        [mcp_servers.other]
        command = "o" # inline comment survives

        """
        #expect(try TOMLTableEditor.member("tablepro", at: ["mcp_servers"], in: text) == .object([
            (key: "command", value: .string("/old")),
            (key: "args", value: .array([.string("--x")])),
            (key: "enabled", value: .bool(false)),
            (key: "env", value: .object([(key: "TOKEN", value: .string("x"))])),
        ]))
        #expect(try TOMLTableEditor.upserting("tablepro", value: MCPClientsFixtures.stdioEntry, at: ["mcp_servers"], in: text) == """
        model = "gpt-5"

        [mcp_servers.tablepro]
        command = "/Applications/TablePro.app/Contents/MacOS/tablepro-mcp"
        args = []

        [mcp_servers.other]
        command = "o" # inline comment survives

        """)
        #expect(try TOMLTableEditor.removing("tablepro", at: ["mcp_servers"], in: text) == """
        model = "gpt-5"

        [mcp_servers.other]
        command = "o" # inline comment survives

        """)
    }

    @Test("Inline tables, dotted keys inside the table and numbers are read")
    func readsHTTPServer() throws {
        let text = """
        [mcp_servers.tablepro]
        url = "http://127.0.0.1:23508/mcp"
        http_headers = { Authorization = "Bearer t" }
        startup_timeout_sec = 1_000
        mask = 0xff
        ratio = 0.5
        env.A = '1'
        created = 1979-05-27 07:32:00Z
        """
        #expect(try TOMLTableEditor.member("tablepro", at: ["mcp_servers"], in: text) == .object([
            (key: "url", value: .string("http://127.0.0.1:23508/mcp")),
            (key: "http_headers", value: .object([(key: "Authorization", value: .string("Bearer t"))])),
            (key: "startup_timeout_sec", value: .number(1_000)),
            (key: "mask", value: .number(255)),
            (key: "ratio", value: .number(0.5)),
            (key: "env", value: .object([(key: "A", value: .string("1"))])),
            (key: "created", value: .string("1979-05-27 07:32:00Z")),
        ]))
    }

    @Test("Nested values render as inline tables and arrays")
    func rendersHTTPEntry() throws {
        let value: JSONValue = .object([
            (key: "url", value: .string("http://127.0.0.1:23508/mcp")),
            (key: "http_headers", value: .object([(key: "Authorization", value: .string("Bearer t"))])),
            (key: "env", value: .object([])),
            (key: "args", value: .array([.string("a b"), .number(2), .bool(true)])),
        ])
        let result = try TOMLTableEditor.upserting("tablepro", value: value, at: ["mcp_servers"], in: "")
        #expect(result == """
        [mcp_servers.tablepro]
        url = "http://127.0.0.1:23508/mcp"
        http_headers = { Authorization = "Bearer t" }
        env = {}
        args = ["a b", 2, true]

        """)
        #expect(try TOMLTableEditor.member("tablepro", at: ["mcp_servers"], in: result) == value)
    }

    @Test("Escapes round trip and odd keys are quoted")
    func escapes() throws {
        let value: JSONValue = .object([
            (key: "command", value: .string("/Apps/Tab\"le\\Pro é\n\u{1}\u{7F}")),
            (key: "odd key", value: .string("x")),
        ])
        let result = try TOMLTableEditor.upserting("my server", value: value, at: ["mcp_servers"], in: "")
        #expect(result.hasPrefix(#"[mcp_servers."my server"]"#))
        #expect(result.contains(#""odd key" = "x""#))
        #expect(try TOMLTableEditor.member("my server", at: ["mcp_servers"], in: result) == value)
    }

    @Test("Headers and arrays inside strings are not taken for tables")
    func lookalikesInStrings() throws {
        let text = """
        notes = \"\"\"
        [mcp_servers.tablepro]
        not a header
        \"\"\"
        args = [
          "[x]",  # comment
          'y',
        ]
        literal = '''
        [mcp_servers.tablepro]
        '''

        """
        #expect(try TOMLTableEditor.member("tablepro", at: ["mcp_servers"], in: text) == nil)
        let result = try TOMLTableEditor.upserting("tablepro", value: entry, at: ["mcp_servers"], in: text)
        #expect(result == text + "\n[mcp_servers.tablepro]\ncommand = \"/b\"\n")
    }

    @Test("Servers defined with dotted keys elsewhere do not stop a table from being added")
    func otherDottedServers() throws {
        let text = "mcp_servers.other.command = \"o\"\n"
        let result = try TOMLTableEditor.upserting("tablepro", value: entry, at: ["mcp_servers"], in: text)
        #expect(result == text + "\n[mcp_servers.tablepro]\ncommand = \"/b\"\n")
    }

    @Test("A server defined any other way is refused", arguments: [
        "[mcp_servers]\ntablepro.command = \"x\"\n",
        "[mcp_servers]\ntablepro = { command = \"x\" }\n",
        "[mcp_servers]\n\"tablepro\" = { command = \"x\" }\n",
        "mcp_servers.tablepro.command = \"x\"\n",
        "mcp_servers = { tablepro = { command = \"x\" } }\n",
        "[[mcp_servers.tablepro]]\ncommand = \"x\"\n",
        "[[mcp_servers]]\nname = \"x\"\n",
    ])
    func unsupportedShapes(text: String) {
        #expect(throws: MCPConfigEditError.unsupportedShape) {
            try TOMLTableEditor.member("tablepro", at: ["mcp_servers"], in: text)
        }
        #expect(throws: MCPConfigEditError.unsupportedShape) {
            try TOMLTableEditor.upserting("tablepro", value: entry, at: ["mcp_servers"], in: text)
        }
        #expect(throws: MCPConfigEditError.unsupportedShape) {
            try TOMLTableEditor.removing("tablepro", at: ["mcp_servers"], in: text)
        }
    }

    @Test("An inline mcp_servers without this server reads as missing but cannot take a table")
    func inlineContainer() throws {
        let text = "mcp_servers = { other = { command = \"o\" } }\n"
        #expect(try TOMLTableEditor.member("tablepro", at: ["mcp_servers"], in: text) == nil)
        #expect(try TOMLTableEditor.removing("tablepro", at: ["mcp_servers"], in: text) == text)
        #expect(throws: MCPConfigEditError.unsupportedShape) {
            try TOMLTableEditor.upserting("tablepro", value: entry, at: ["mcp_servers"], in: text)
        }
    }

    @Test("The same table twice is refused")
    func duplicateTable() {
        let text = "[mcp_servers.tablepro]\ncommand = \"a\"\n[mcp_servers.tablepro]\ncommand = \"b\"\n"
        #expect(throws: MCPConfigEditError.duplicateKey(["mcp_servers", "tablepro"])) {
            try TOMLTableEditor.member("tablepro", at: ["mcp_servers"], in: text)
        }
    }

    @Test("CRLF files and files without a final line break get matching line breaks")
    func lineBreaks() throws {
        #expect(try TOMLTableEditor.upserting("tablepro", value: entry, at: ["mcp_servers"], in: "model = \"x\"\r\n")
            == "model = \"x\"\r\n\r\n[mcp_servers.tablepro]\r\ncommand = \"/b\"\r\n")
        #expect(try TOMLTableEditor.upserting("tablepro", value: entry, at: ["mcp_servers"], in: "model = \"x\"")
            == "model = \"x\"\n\n[mcp_servers.tablepro]\ncommand = \"/b\"\n")
        #expect(try TOMLTableEditor.upserting("tablepro", value: entry, at: ["mcp_servers"], in: "[mcp_servers.tablepro]\ncommand = \"/old\"")
            == "[mcp_servers.tablepro]\ncommand = \"/b\"")
        #expect(try TOMLTableEditor.upserting("tablepro", value: entry, at: ["mcp_servers"], in: "") == "[mcp_servers.tablepro]\ncommand = \"/b\"\n")
        #expect(try TOMLTableEditor.removing("tablepro", at: ["mcp_servers"], in: "") == "")
    }

    @Test("A null value cannot be written")
    func nullRefused() {
        #expect(throws: MCPConfigEditError.unsupportedShape) {
            try TOMLTableEditor.upserting("tablepro", value: .object([(key: "x", value: .null)]), at: ["mcp_servers"], in: "")
        }
    }

    @Test("Broken syntax is refused", arguments: [
        "model = \n", "[mcp_servers\n", "a = \"unterminated\n", "a = 1 b = 2\n", "a = [1, 2\n", "a = bare\n",
    ])
    func invalidSyntax(text: String) {
        #expect(throws: MCPConfigEditError.invalidSyntax) {
            try TOMLTableEditor.member("tablepro", at: ["mcp_servers"], in: text)
        }
    }

    @Test("Merging rewrites only the keys the entry names and keeps every other key and subtable")
    func mergeKeepsUserKeys() throws {
        let text = """
        model = "gpt-5"

        [mcp_servers.tablepro]
        command = "/old" # old
        args = ["--x"]
        enabled_tools = ["list_connections"]
        startup_timeout_sec = 30

        [mcp_servers.tablepro.env]
        TOKEN = "x"

        [mcp_servers.other]
        command = "o"

        """
        let result = try TOMLTableEditor.merging("tablepro", value: MCPClientsFixtures.stdioEntry, at: ["mcp_servers"], in: text)
        #expect(result == """
        model = "gpt-5"

        [mcp_servers.tablepro]
        command = "/Applications/TablePro.app/Contents/MacOS/tablepro-mcp"
        args = []
        enabled_tools = ["list_connections"]
        startup_timeout_sec = 30

        [mcp_servers.tablepro.env]
        TOKEN = "x"

        [mcp_servers.other]
        command = "o"

        """)
        #expect(try TOMLTableEditor.merging("tablepro", value: MCPClientsFixtures.stdioEntry, at: ["mcp_servers"], in: result) == result)
    }

    @Test("Merging adds a missing key after the table's last key, keeping CRLF and a missing final line break")
    func mergeAddsKeys() throws {
        let text = "[mcp_servers.tablepro]\r\ncommand = \"/old\"\r\nenabled = false\r\n\r\n[other]\r\nx = 1\r\n"
        #expect(try TOMLTableEditor.merging("tablepro", value: MCPClientsFixtures.stdioEntry, at: ["mcp_servers"], in: text)
            == "[mcp_servers.tablepro]\r\ncommand = \"/Applications/TablePro.app/Contents/MacOS/tablepro-mcp\"\r\nenabled = false\r\n"
            + "args = []\r\n\r\n[other]\r\nx = 1\r\n")
        #expect(try TOMLTableEditor.merging("tablepro", value: MCPClientsFixtures.stdioEntry, at: ["mcp_servers"], in: "[mcp_servers.tablepro]\nx = 1")
            == "[mcp_servers.tablepro]\nx = 1\ncommand = \"/Applications/TablePro.app/Contents/MacOS/tablepro-mcp\"\nargs = []\n")
    }

    @Test("A table the entry names is merged into, and rewritten inline only when its contents change")
    func mergeNestedTables() throws {
        let text = "[mcp_servers.tablepro]\ncommand = \"/b\"\n\n[mcp_servers.tablepro.env]\nTOKEN = \"x\"\n\n[profiles.fast]\nmodel = \"m\"\n"
        let keepsEnv: JSONValue = .object([(key: "command", value: .string("/b")), (key: "env", value: .object([]))])
        #expect(try TOMLTableEditor.merging("tablepro", value: keepsEnv, at: ["mcp_servers"], in: text) == text)

        let addsToEnv: JSONValue = .object([(key: "env", value: .object([(key: "NEW", value: .string("y"))]))])
        let merged = try TOMLTableEditor.merging("tablepro", value: addsToEnv, at: ["mcp_servers"], in: text)
        #expect(merged == "[mcp_servers.tablepro]\ncommand = \"/b\"\nenv = { TOKEN = \"x\", NEW = \"y\" }\n\n[profiles.fast]\nmodel = \"m\"\n")

        let dotted = "[mcp_servers.tablepro]\nenv.A = \"1\"\ncommand = \"/b\"\nenv.B = \"2\"\n"
        #expect(try TOMLTableEditor.merging("tablepro", value: addsToEnv, at: ["mcp_servers"], in: dotted)
            == "[mcp_servers.tablepro]\nenv = { A = \"1\", B = \"2\", NEW = \"y\" }\ncommand = \"/b\"\n")
    }

    @Test("Merging into a server that has only subtables adds its table at the end")
    func mergeWithoutMainTable() throws {
        let text = "[mcp_servers.tablepro.env]\nTOKEN = \"x\"\n"
        let result = try TOMLTableEditor.merging("tablepro", value: MCPClientsFixtures.stdioEntry, at: ["mcp_servers"], in: text)
        #expect(result == text + "\n[mcp_servers.tablepro]\ncommand = \"/Applications/TablePro.app/Contents/MacOS/tablepro-mcp\"\nargs = []\n")
    }

    @Test("Merging a missing server is the same as adding it, and other shapes are still refused")
    func mergeFallsBack() throws {
        #expect(try TOMLTableEditor.merging("tablepro", value: entry, at: ["mcp_servers"], in: codexConfig)
            == TOMLTableEditor.upserting("tablepro", value: entry, at: ["mcp_servers"], in: codexConfig))
        #expect(throws: MCPConfigEditError.unsupportedShape) {
            try TOMLTableEditor.merging("tablepro", value: entry, at: ["mcp_servers"], in: "[mcp_servers]\ntablepro = { command = \"x\" }\n")
        }
        #expect(throws: MCPConfigEditError.unsupportedShape) {
            try TOMLTableEditor.merging("tablepro", value: entry, at: ["mcp_servers"], in: "mcp_servers = { other = {} }\n")
        }
    }
}
