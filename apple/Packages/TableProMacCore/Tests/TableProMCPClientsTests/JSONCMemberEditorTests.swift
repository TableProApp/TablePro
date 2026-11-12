import Foundation
@testable import TableProMCPClients
import Testing

struct JSONCMemberEditorTests {
    private let entry: JSONValue = .object([(key: "command", value: .string("/b"))])

    @Test("A member is read through comments and trailing commas")
    func readsThroughComments() throws {
        let text = """
        // Zed settings
        //
        // documentation: https://zed.dev/docs/configuring-zed
        {
          "ui_font_size": 16,
          /* servers */
          "context_servers": {
            "tablepro": {
              "command": "/b", // bridge
              "args": [],
            },
          },
        }
        """
        let member = try JSONCMemberEditor.member("tablepro", at: ["context_servers"], in: text)
        #expect(member == .object([(key: "command", value: .string("/b")), (key: "args", value: .array([]))]))
        #expect(try JSONCMemberEditor.member("other", at: ["context_servers"], in: text) == nil)
        #expect(try JSONCMemberEditor.member("tablepro", at: ["missing"], in: text) == nil)
    }

    @Test("Strings that look like comments and escapes are read as strings")
    func stringsAndEscapes() throws {
        let text = #"{"url": "http://x//y/*z*/", "quote": "a\"b\\cé😀", "mcpServers": {}}"#
        #expect(try JSONCMemberEditor.member("url", at: [], in: text) == .string("http://x//y/*z*/"))
        #expect(try JSONCMemberEditor.member("quote", at: [], in: text) == .string("a\"b\\c\u{e9}\u{1F600}"))
    }

    @Test("Inserting into an existing container keeps comments, order and the file's four-space indent")
    func insertKeepsLayout() throws {
        let text = """
        {
            // Servers I use
            "mcpServers": {
                "other": {
                    "command": "/usr/local/bin/other" // keep
                }
            },
            /* trailing block */
            "theme": "dark"
        }

        """
        let result = try JSONCMemberEditor.upserting("tablepro", value: MCPClientsFixtures.stdioEntry, at: ["mcpServers"], in: text)
        #expect(result == """
        {
            // Servers I use
            "mcpServers": {
                "other": {
                    "command": "/usr/local/bin/other" // keep
                },
                "tablepro": {
                    "command": "/Applications/TablePro.app/Contents/MacOS/tablepro-mcp",
                    "args": []
                }
            },
            /* trailing block */
            "theme": "dark"
        }

        """)
        #expect(try JSONCMemberEditor.removing("tablepro", at: ["mcpServers"], in: result) == text)
    }

    @Test("A missing container is created after the last top-level key")
    func createsContainer() throws {
        let text = """
        {
          "coworkUserFilesPath": "/Users/me/Claude",
          "preferences": {
            "quickEntry": true
          }
        }
        """
        let result = try JSONCMemberEditor.upserting("tablepro", value: MCPClientsFixtures.stdioEntry, at: ["mcpServers"], in: text)
        #expect(result == """
        {
          "coworkUserFilesPath": "/Users/me/Claude",
          "preferences": {
            "quickEntry": true
          },
          "mcpServers": {
            "tablepro": {
              "command": "/Applications/TablePro.app/Contents/MacOS/tablepro-mcp",
              "args": []
            }
          }
        }
        """)
    }

    @Test("Every missing object along a longer key path is created")
    func createsNestedPath() throws {
        let result = try JSONCMemberEditor.upserting("tablepro", value: entry, at: ["mcp", "servers"], in: "{}\n")
        #expect(result == """
        {
          "mcp": {
            "servers": {
              "tablepro": {
                "command": "/b"
              }
            }
          }
        }

        """)
        let partial = try JSONCMemberEditor.upserting("tablepro", value: entry, at: ["mcp", "servers"], in: #"{"mcp": {"a": 1}}"#)
        #expect(partial == #"{"mcp": {"a": 1, "servers": {"tablepro": {"command": "/b"}}}}"#)
    }

    @Test("An existing member is replaced where it stands")
    func replacesInPlace() throws {
        let text = """
        {
          "mcpServers": {
            "tablepro": {
              "command": "/old/path",
              "args": ["--x"]
            },
            "other": { "command": "o" }
          }
        }
        """
        let result = try JSONCMemberEditor.upserting("tablepro", value: MCPClientsFixtures.stdioEntry, at: ["mcpServers"], in: text)
        #expect(result == """
        {
          "mcpServers": {
            "tablepro": {
              "command": "/Applications/TablePro.app/Contents/MacOS/tablepro-mcp",
              "args": []
            },
            "other": { "command": "o" }
          }
        }
        """)
        #expect(try JSONCMemberEditor.upserting("tablepro", value: MCPClientsFixtures.stdioEntry, at: ["mcpServers"], in: result) == result)
    }

    @Test("A file with trailing commas and tabs keeps both")
    func trailingCommasAndTabs() throws {
        let text = [
            "{",
            "\t// VS Code MCP",
            "\t\"servers\": {",
            "\t\t\"other\": {",
            "\t\t\t\"type\": \"stdio\",",
            "\t\t\t\"command\": \"o\",",
            "\t\t},",
            "\t},",
            "\t\"inputs\": [],",
            "}",
        ].joined(separator: "\n")
        let result = try JSONCMemberEditor.upserting("tablepro", value: entry, at: ["servers"], in: text)
        #expect(result == [
            "{",
            "\t// VS Code MCP",
            "\t\"servers\": {",
            "\t\t\"other\": {",
            "\t\t\t\"type\": \"stdio\",",
            "\t\t\t\"command\": \"o\",",
            "\t\t},",
            "\t\t\"tablepro\": {",
            "\t\t\t\"command\": \"/b\"",
            "\t\t},",
            "\t},",
            "\t\"inputs\": [],",
            "}",
        ].joined(separator: "\n"))
        #expect(try JSONCMemberEditor.removing("tablepro", at: ["servers"], in: result) == text)
    }

    @Test("CRLF line breaks are kept")
    func crlf() throws {
        let result = try JSONCMemberEditor.upserting("tablepro", value: entry, at: ["mcpServers"], in: "{\r\n  \"a\": 1\r\n}\r\n")
        #expect(result == "{\r\n  \"a\": 1,\r\n  \"mcpServers\": {\r\n    \"tablepro\": {\r\n      \"command\": \"/b\"\r\n    }\r\n  }\r\n}\r\n")
    }

    @Test("Empty, blank and comment-only files count as an empty object")
    func emptyFiles() throws {
        let expected = """
        {
          "mcpServers": {
            "tablepro": {
              "command": "/b"
            }
          }
        }

        """
        #expect(try JSONCMemberEditor.upserting("tablepro", value: entry, at: ["mcpServers"], in: "") == expected)
        #expect(try JSONCMemberEditor.upserting("tablepro", value: entry, at: ["mcpServers"], in: "  \n") == expected)
        #expect(try JSONCMemberEditor.upserting("tablepro", value: entry, at: ["mcpServers"], in: "// my config") == "// my config\n" + expected)
        #expect(try JSONCMemberEditor.upserting("tablepro", value: entry, at: ["mcpServers"], in: "/* a */\n") == "/* a */\n" + expected)
        #expect(try JSONCMemberEditor.member("tablepro", at: ["mcpServers"], in: "// only a comment") == nil)
        #expect(try JSONCMemberEditor.removing("tablepro", at: ["mcpServers"], in: "// only a comment") == "// only a comment")
        #expect(try JSONCMemberEditor.removing("tablepro", at: ["mcpServers"], in: "") == "")
    }

    @Test("An empty container opens up at the file's indent, after any comment inside it")
    func emptyContainers() throws {
        let inline = """
        {
          "mcpServers": {},
          "x": 1
        }
        """
        #expect(try JSONCMemberEditor.upserting("tablepro", value: entry, at: ["mcpServers"], in: inline) == """
        {
          "mcpServers": {
            "tablepro": {
              "command": "/b"
            }
          },
          "x": 1
        }
        """)
        let commented = """
        {
          "context_servers": {
            // none yet
          }
        }
        """
        #expect(try JSONCMemberEditor.upserting("tablepro", value: entry, at: ["context_servers"], in: commented) == """
        {
          "context_servers": {
            // none yet
            "tablepro": {
              "command": "/b"
            }
          }
        }
        """)
    }

    @Test("A minified file stays on one line")
    func minified() throws {
        let text = #"{"mcpServers":{"other":{"command":"o"}}}"#
        let result = try JSONCMemberEditor.upserting("tablepro", value: entry, at: ["mcpServers"], in: text)
        #expect(result == #"{"mcpServers":{"other":{"command":"o"},"tablepro":{"command":"/b"}}}"#)
        #expect(try JSONCMemberEditor.removing("tablepro", at: ["mcpServers"], in: result) == text)
    }

    @Test("Removing a middle member takes its line, comma and comment")
    func removeMiddle() throws {
        let text = """
        {
          "mcpServers": {
            "a": {},
            "tablepro": {
              "command": "/b"
            }, // ours
            "c": {}
          }
        }
        """
        #expect(try JSONCMemberEditor.removing("tablepro", at: ["mcpServers"], in: text) == """
        {
          "mcpServers": {
            "a": {},
            "c": {}
          }
        }
        """)
    }

    @Test("Removing the only member leaves an empty container")
    func removeOnly() throws {
        let text = """
        {
          "mcpServers": {
            "tablepro": {
              "command": "/b"
            }
          },
          "x": 1
        }
        """
        #expect(try JSONCMemberEditor.removing("tablepro", at: ["mcpServers"], in: text) == """
        {
          "mcpServers": {},
          "x": 1
        }
        """)
    }

    @Test("Removing from one line keeps the separators valid")
    func removeInline() throws {
        #expect(try JSONCMemberEditor.removing("tablepro", at: ["mcpServers"], in: #"{"mcpServers": {"a": 1, "tablepro": {"command": "/b"}}}"#)
            == #"{"mcpServers": {"a": 1}}"#)
        #expect(try JSONCMemberEditor.removing("tablepro", at: ["mcpServers"], in: #"{"mcpServers": {"tablepro": {}, "a": 1}}"#)
            == #"{"mcpServers": {"a": 1}}"#)
        #expect(try JSONCMemberEditor.removing("tablepro", at: ["mcpServers"], in: #"{"mcpServers": { "tablepro": {} }}"#)
            == #"{"mcpServers": {}}"#)
    }

    @Test("Removing a member that is not there changes nothing")
    func removeAbsent() throws {
        let text = "{\n  // keep\n  \"mcpServers\": {\"a\": 1}\n}\n"
        #expect(try JSONCMemberEditor.removing("tablepro", at: ["mcpServers"], in: text) == text)
        #expect(try JSONCMemberEditor.removing("tablepro", at: ["missing"], in: text) == text)
    }

    @Test("A duplicate key on the walked path is refused")
    func duplicateKeys() {
        let duplicateContainer = #"{"mcpServers": {}, "mcpServers": {}}"#
        #expect(throws: MCPConfigEditError.duplicateKey(["mcpServers"])) {
            try JSONCMemberEditor.member("tablepro", at: ["mcpServers"], in: duplicateContainer)
        }
        #expect(throws: MCPConfigEditError.duplicateKey(["mcpServers"])) {
            try JSONCMemberEditor.upserting("tablepro", value: entry, at: ["mcpServers"], in: duplicateContainer)
        }
        #expect(throws: MCPConfigEditError.duplicateKey(["mcpServers"])) {
            try JSONCMemberEditor.removing("tablepro", at: ["mcpServers"], in: duplicateContainer)
        }
        let duplicateMember = #"{"mcpServers": {"tablepro": {}, "tablepro": {}}}"#
        #expect(throws: MCPConfigEditError.duplicateKey(["mcpServers", "tablepro"])) {
            try JSONCMemberEditor.upserting("tablepro", value: entry, at: ["mcpServers"], in: duplicateMember)
        }
        #expect(throws: MCPConfigEditError.duplicateKey(["mcp", "servers"])) {
            try JSONCMemberEditor.upserting("tablepro", value: entry, at: ["mcp", "servers"], in: #"{"mcp": {"servers": {}, "servers": {}}}"#)
        }
    }

    @Test("A non-object on the path is refused")
    func notAnObject() {
        #expect(throws: MCPConfigEditError.notAnObject(["mcpServers"])) {
            try JSONCMemberEditor.upserting("tablepro", value: entry, at: ["mcpServers"], in: #"{"mcpServers": []}"#)
        }
        #expect(throws: MCPConfigEditError.notAnObject(["mcp", "servers"])) {
            try JSONCMemberEditor.member("tablepro", at: ["mcp", "servers"], in: #"{"mcp": {"servers": "x"}}"#)
        }
        #expect(throws: MCPConfigEditError.notAnObject([])) {
            try JSONCMemberEditor.removing("tablepro", at: ["mcpServers"], in: "[]")
        }
    }

    @Test("Broken syntax is refused", arguments: [
        #"{"a": }"#, #"{"a": 1 /* open"#, #"{"a" 1}"#, "{,}", #"{"a": 1,,}"#, #"{"a": 'x'}"#, #"{"a": 01}"#, "{} {}", "{\"a\": \"\n\"}",
    ])
    func invalidSyntax(text: String) {
        #expect(throws: MCPConfigEditError.invalidSyntax) {
            try JSONCMemberEditor.upserting("tablepro", value: .object([]), at: ["mcpServers"], in: text)
        }
    }

    @Test("Escapes and non-ASCII text round trip through an edit")
    func escapesRoundTrip() throws {
        let value: JSONValue = .object([
            (key: "command", value: .string("/Apps/Tab\"le\\Pro é\n\u{1}/bridge")),
            (key: "timeout", value: .number(300)),
            (key: "ratio", value: .number(0.5)),
            (key: "enabled", value: .bool(false)),
            (key: "extra", value: .null),
        ])
        let text = "{\n  \"név\": \"ő\"\n}\n"
        let result = try JSONCMemberEditor.upserting("tablepro", value: value, at: ["mcpServers"], in: text)
        #expect(try JSONCMemberEditor.member("tablepro", at: ["mcpServers"], in: result) == value)
        #expect(result.hasPrefix("{\n  \"név\": \"ő\",\n"))
        #expect(result.contains(#""timeout": 300,"#))
        let parsed = try MCPClientsFixtures.parsed(result)
        let servers = try #require(parsed["mcpServers"] as? NSDictionary)
        let server = try #require(servers["tablepro"] as? NSDictionary)
        #expect(server["command"] as? String == "/Apps/Tab\"le\\Pro é\n\u{1}/bridge")
    }

    @Test("A duplicate key elsewhere in the file does not block the edit")
    func unrelatedDuplicate() throws {
        let text = "{\n  \"a\": 1,\n  \"a\": 2,\n  \"mcpServers\": {}\n}"
        let result = try JSONCMemberEditor.upserting("tablepro", value: entry, at: ["mcpServers"], in: text)
        #expect(try JSONCMemberEditor.member("tablepro", at: ["mcpServers"], in: result) == entry)
    }

    @Test("Merging rewrites only the members the entry names and keeps the rest where they stand")
    func mergeKeepsUserMembers() throws {
        let text = """
        {
          "mcpServers": {
            "tablepro": {
              "command": "/old/path", // moved
              "args": ["--x"],
              "autoApprove": ["list_connections"],
              "env": { "A": "1" },
              "timeout": 30
            }
          }
        }
        """
        let value: JSONValue = .object([
            (key: "command", value: .string("/b")),
            (key: "args", value: .array([])),
            (key: "env", value: .object([])),
            (key: "type", value: .string("stdio")),
        ])
        let result = try JSONCMemberEditor.merging("tablepro", value: value, at: ["mcpServers"], in: text)
        #expect(result == """
        {
          "mcpServers": {
            "tablepro": {
              "command": "/b", // moved
              "args": [],
              "autoApprove": ["list_connections"],
              "env": { "A": "1" },
              "timeout": 30,
              "type": "stdio"
            }
          }
        }
        """)
        #expect(try JSONCMemberEditor.merging("tablepro", value: value, at: ["mcpServers"], in: result) == result)
    }

    @Test("Merging a missing or non-object entry writes the whole value")
    func mergeWithoutEntry() throws {
        let missing = #"{"mcpServers": {"other": {}}}"#
        #expect(try JSONCMemberEditor.merging("tablepro", value: entry, at: ["mcpServers"], in: missing)
            == JSONCMemberEditor.upserting("tablepro", value: entry, at: ["mcpServers"], in: missing))
        #expect(try JSONCMemberEditor.merging("tablepro", value: entry, at: ["mcpServers"], in: #"{"mcpServers": {"tablepro": "x"}}"#)
            == #"{"mcpServers": {"tablepro": {"command": "/b"}}}"#)
        #expect(try JSONCMemberEditor.merging("tablepro", value: entry, at: ["mcpServers"], in: "")
            == JSONCMemberEditor.upserting("tablepro", value: entry, at: ["mcpServers"], in: ""))
    }

    @Test("An unpaired surrogate escape, which Node writes, reads as U+FFFD and survives an edit unchanged")
    func loneSurrogates() throws {
        func escape(_ hex: String) -> String { "\\" + "u" + hex }
        for title in [escape("d83d"), escape("dc00") + "x", escape("d83d") + escape("0041")] {
            let text = "{\n  \"title\": \"" + title + "\",\n  \"mcpServers\": {}\n}\n"
            let added = try JSONCMemberEditor.upserting("tablepro", value: entry, at: ["mcpServers"], in: text)
            #expect(added.contains("\"title\": \"" + title + "\","))
            #expect(try JSONCMemberEditor.member("tablepro", at: ["mcpServers"], in: added) == entry)
            #expect(try JSONCMemberEditor.member("title", at: [], in: added)?.stringValue?.hasPrefix("\u{FFFD}") == true)
            #expect(try JSONCMemberEditor.removing("tablepro", at: ["mcpServers"], in: added) == text)
        }
        let pair = escape("d83d") + escape("de00")
        #expect(try JSONCMemberEditor.member("t", at: [], in: "{\"t\": \"" + pair + "\"}") == .string("\u{1F600}"))
    }
}
