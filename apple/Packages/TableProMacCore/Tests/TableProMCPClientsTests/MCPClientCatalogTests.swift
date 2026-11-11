import Foundation
@testable import TableProMCPClients
import Testing

struct MCPClientCatalogTests {
    @Test("The bundled catalog decodes")
    func decodesBundledCatalog() throws {
        let catalog = try MCPClientsFixtures.catalog()
        #expect(catalog.schemaVersion == 1)
        #expect(catalog.serverName == "tablepro")
        #expect(catalog.clients.first?.id == "claude-desktop")
        #expect(catalog.clients.count > 10)
    }

    @Test("Client ids are unique")
    func clientIDsAreUnique() throws {
        let ids = try MCPClientsFixtures.catalog().clients.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Every config id resolves for each platform the client has")
    func everyConfigResolves() throws {
        let catalog = try MCPClientsFixtures.catalog()
        for client in catalog.clients {
            guard let configID = client.configID else { continue }
            #expect(catalog.configs[configID] != nil, "\(client.id) names \(configID)")
            for platform in MCPClientPlatform.allCases where client.spec(for: platform) != nil {
                #expect(catalog.location(for: client, platform: platform) != nil, "\(client.id) on \(platform)")
            }
        }
    }

    @Test("Every client renders its entry, arguments and deeplinks on both platforms")
    func everyClientRenders() throws {
        let catalog = try MCPClientsFixtures.catalog()
        var rendered = 0
        for client in catalog.clients {
            for platform in MCPClientPlatform.allCases {
                guard let spec = client.spec(for: platform) else { continue }
                if spec.unsupported != nil {
                    #expect(spec.install.isEmpty, "\(client.id) on \(platform) is unsupported but installs")
                    continue
                }
                let renderer = MCPClientsFixtures.renderer(for: platform)
                let entry = try renderer.entry(spec)
                #expect(!MCPClientsFixtures.hasPlaceholder(entry.compactText), "\(client.id) on \(platform): \(entry.compactText)")
                for method in spec.install {
                    switch method {
                    case let .deeplink(scheme, template):
                        let url = try renderer.url(template, entry: entry)
                        #expect(url.scheme == scheme)
                    case .cli(let cli):
                        let added = try renderer.arguments(cli.add, entry: entry)
                        #expect(!added.contains { MCPClientsFixtures.hasPlaceholder($0) })
                        if let remove = cli.remove {
                            #expect(try renderer.arguments(remove, entry: entry).contains("tablepro"))
                        }
                    case .file:
                        let location = try #require(catalog.location(for: client, platform: platform))
                        #expect(location.isWritable, "\(client.id) on \(platform) offers a file install on a read-only config")
                    }
                }
                _ = renderer.snippet(for: catalog.location(for: client, platform: platform), entry: entry)
                rendered += 1
            }
        }
        #expect(rendered > 20)
    }

    @Test("Entries keep the catalog's key order")
    func entryKeyOrder() throws {
        let catalog = try MCPClientsFixtures.catalog()
        let spec = try #require(catalog.client(id: "claude-code")?.spec(for: .macos))
        let entry = try MCPClientsFixtures.renderer(for: .macos).entry(spec)
        #expect(entry.objectMembers?.map(\.key) == ["type", "command", "args", "env"])
    }

    @Test("Locations decode their defaults and flags")
    func locations() throws {
        let catalog = try MCPClientsFixtures.catalog()
        let claudeCode = try #require(catalog.client(id: "claude-code"))
        let location = try #require(catalog.location(for: claudeCode, platform: .macos))
        #expect(location.format == .json)
        #expect(location.keyPath == ["mcpServers"])
        #expect(!location.isWritable)
        #expect(location.otherScopes == [["projects", "*", "mcpServers"]])

        let cursor = try #require(catalog.client(id: "cursor"))
        let cursorLocation = try #require(catalog.location(for: cursor, platform: .macos))
        #expect(cursorLocation.isWritable)
        #expect(cursorLocation.otherScopes.isEmpty)
        #expect(cursorLocation.alternateKeyPaths.isEmpty)
        #expect(catalog.location(for: try MCPClientsFixtures.client("raycast"), platform: .macos) == nil)

        let opencode = try MCPClientsFixtures.location("opencode")
        #expect(opencode.keyPath == ["mcp", "servers"])
        #expect(opencode.alternateKeyPaths == [["mcp"]])
        #expect(opencode.otherScopes.isEmpty)
    }

    @Test("Detect rules and install methods decode")
    func detectAndInstall() throws {
        let catalog = try MCPClientsFixtures.catalog()
        let cursor = try #require(catalog.client(id: "cursor")?.spec(for: .macos))
        #expect(cursor.detect == [.bundleID("com.todesktop.230313mzl4w4u92"), .path("~/.cursor")])
        #expect(cursor.install.last == .file)
        #expect(cursor.applies == .live)

        let claudeCode = try #require(catalog.client(id: "claude-code")?.spec(for: .macos))
        guard case .cli(let cli)? = claudeCode.install.first else {
            Issue.record("claude-code installs through its CLI")
            return
        }
        #expect(cli.binary == "claude")
        #expect(cli.update == .removeThenAdd)
        #expect(cli.remove == ["mcp", "remove", "--scope", "user", "{name}"])

        let opencode = try #require(catalog.client(id: "opencode")?.spec(for: .macos))
        guard case .cli(let opencodeCLI)? = opencode.install.first else {
            Issue.record("opencode installs through its CLI")
            return
        }
        #expect(opencodeCLI.remove == nil)
        #expect(opencodeCLI.update == .add)

        let classic = try #require(catalog.client(id: "chatgpt-classic"))
        #expect(classic.configID == nil)
        #expect(classic.spec(for: .macos)?.unsupported == .remoteOnly)
        #expect(classic.spec(for: .linux) == nil)
    }

    @Test("clientInfo names match exactly first, then by the longest prefix, ignoring case")
    func clientInfoMatching() throws {
        let catalog = try MCPClientsFixtures.catalog()
        #expect(catalog.client(matchingClientInfoName: "claude-code")?.id == "claude-code")
        #expect(catalog.client(matchingClientInfoName: "CLAUDE-AI")?.id == "claude-desktop")
        #expect(catalog.client(matchingClientInfoName: "Visual Studio Code")?.id == "vscode")
        #expect(catalog.client(matchingClientInfoName: "Visual-Studio-Code")?.id == "vscode")
        #expect(catalog.client(matchingClientInfoName: "Visual Studio Code - Insiders")?.id == "vscode-insiders")
        #expect(catalog.client(matchingClientInfoName: "zed")?.id == "zed")
        #expect(catalog.client(matchingClientInfoName: "goose-cli")?.id == "goose")
        #expect(catalog.client(matchingClientInfoName: "goose-server")?.id == "goose")
        #expect(catalog.client(matchingClientInfoName: "something-else") == nil)
        #expect(catalog.client(matchingClientInfoName: "") == nil)
    }

    @Test("A clientInfo name two clients send is the one detected here, or neither")
    func sharedClientInfoName() throws {
        let catalog = try MCPClientsFixtures.catalog()
        #expect(catalog.clients(matchingClientInfoName: "codex-mcp-client").map { $0.id } == ["chatgpt", "codex"])
        #expect(catalog.clients(matchingClientInfoName: "Visual Studio Code - Insiders").map { $0.id } == ["vscode-insiders"])
        #expect(catalog.client(matchingClientInfoName: "Codex", detected: ["codex"])?.id == "codex")
        #expect(catalog.client(matchingClientInfoName: "codex-mcp-client", detected: ["chatgpt", "cursor"])?.id == "chatgpt")
        #expect(catalog.client(matchingClientInfoName: "codex-mcp-client", detected: ["chatgpt", "codex"]) == nil)
        #expect(catalog.client(matchingClientInfoName: "codex-mcp-client", detected: []) == nil)
        #expect(catalog.client(matchingClientInfoName: "claude-code", detected: [])?.id == "claude-code")
    }

    @Test("The HTTP entry is the first platform entry that names {url}")
    func httpEntry() throws {
        let catalog = try MCPClientsFixtures.catalog()
        let claudeCode = try #require(catalog.client(id: "claude-code"))
        let entry = try #require(catalog.httpEntry(for: claudeCode))
        #expect(entry["type"] == .string("http"))
        #expect(entry["url"] == .string("{url}"))

        let rendered = try MCPClientsFixtures.renderer(for: .linux).entry(template: entry)
        #expect(rendered["headers"]?["Authorization"] == .string(MCPClientsFixtures.authorization))

        #expect(catalog.httpEntry(for: try MCPClientsFixtures.client("claude-desktop")) == nil)
        #expect(catalog.httpEntry(for: try MCPClientsFixtures.client("chatgpt-classic")) == nil)
        #expect(catalog.httpEntry(for: try MCPClientsFixtures.client("raycast")) == nil)
    }

    @Test("A newer schema version is refused")
    func newerSchemaRefused() {
        let data = Data(#"{"schemaVersion": 2, "serverName": "tablepro", "configs": {}, "clients": []}"#.utf8)
        #expect(throws: MCPClientCatalogError.unsupportedSchemaVersion(2)) {
            try MCPClientCatalog.decode(data)
        }
    }

    @Test("A missing field names its path")
    func missingFieldPath() {
        let data = Data(#"{"schemaVersion": 1, "serverName": "tablepro", "configs": {}, "clients": [{"id": "x", "icon": "x"}]}"#.utf8)
        #expect(throws: MCPClientCatalogError.invalidField(["clients", "0", "name"])) {
            try MCPClientCatalog.decode(data)
        }
    }

    @Test("An unknown install kind is refused")
    func unknownInstallKind() {
        let data = Data(#"""
        {"schemaVersion": 1, "serverName": "tablepro", "configs": {},
         "clients": [{"id": "x", "name": "X", "icon": "x", "config": null, "macos": {"install": [{"kind": "magic"}]}}]}
        """#.utf8)
        #expect(throws: MCPClientCatalogError.invalidField(["clients", "0", "macos", "install", "0", "kind"])) {
            try MCPClientCatalog.decode(data)
        }
    }

    @Test("Decoding through JSONDecoder gives the same clients")
    func jsonDecoderConformance() throws {
        let data = try Data(contentsOf: MCPClientsFixtures.catalogURL)
        let decoded = try JSONDecoder().decode(MCPClientCatalog.self, from: data)
        #expect(decoded.clients.map(\.id) == (try MCPClientsFixtures.catalog()).clients.map(\.id))
    }
}
