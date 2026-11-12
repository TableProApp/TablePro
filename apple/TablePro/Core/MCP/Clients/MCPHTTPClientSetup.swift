import Foundation
import TableProMCPClients

struct MCPHTTPClientChoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct MCPHTTPClientSnippet: Equatable, Sendable {
    let displayConfigPath: String?
    let commandLine: String?
    let snippet: String?
}

struct MCPHTTPClientSetup: Sendable {
    static let otherClientID = "__other__"

    let catalog: MCPClientCatalog?
    let context: MCPClientSetupContext
    let url: String

    init(catalog: MCPClientCatalog? = MCPClientCatalogBundle.shared, context: MCPClientSetupContext = .live(), port: Int) {
        self.catalog = catalog
        self.context = context
        self.url = "http://127.0.0.1:\(port)/mcp"
    }

    var choices: [MCPHTTPClientChoice] {
        let catalogChoices = (catalog?.clients ?? [])
            .filter { $0.spec(for: .macos) != nil && catalog?.httpEntry(for: $0) != nil }
            .map { MCPHTTPClientChoice(id: $0.id, name: $0.name) }
        return catalogChoices + [MCPHTTPClientChoice(id: Self.otherClientID, name: String(localized: "Other Client"))]
    }

    static func authorization(token: String) -> String {
        "Bearer \(token)"
    }

    func render(clientID: String, token: String) -> MCPHTTPClientSnippet? {
        guard let catalog,
              let client = catalog.client(id: clientID),
              let template = catalog.httpEntry(for: client),
              let spec = Self.platformSpec(of: client, holding: template)
        else { return nil }
        let renderer = MCPTemplateRenderer(
            serverName: catalog.serverName,
            target: .http(url: url, authorization: Self.authorization(token: token))
        )
        guard let entry = try? renderer.entry(spec) else { return nil }
        let location = catalog.location(for: client, platform: .macos) ?? catalog.location(for: client, platform: .linux)
        let commandLine = spec.cliInstall.flatMap { cli in
            (try? renderer.arguments(cli.add, entry: entry)).map { renderer.commandLine(binary: cli.binary, arguments: $0) }
        }
        let isWritable = location?.isWritable ?? true
        return MCPHTTPClientSnippet(
            displayConfigPath: location.map { context.displayPath(context.expand($0.path)) },
            commandLine: commandLine,
            snippet: commandLine != nil && !isWritable ? nil : renderer.snippet(for: location, entry: entry)
        )
    }

    // The HTTP entry is written for whichever platform serves TablePro over HTTP; its spec carries the matching CLI.
    private static func platformSpec(of client: MCPClientDefinition, holding entry: JSONValue) -> MCPClientPlatformSpec? {
        [MCPClientPlatform.macos, .linux]
            .lazy
            .compactMap { client.spec(for: $0) }
            .first { $0.entry == entry }
    }
}
