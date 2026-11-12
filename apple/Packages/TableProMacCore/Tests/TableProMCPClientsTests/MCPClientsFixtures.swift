import Foundation
@testable import TableProMCPClients
import Testing

enum MCPClientsFixtures {
    static let bridge = "/Applications/TablePro.app/Contents/MacOS/tablepro-mcp"
    static let betaBridge = "/Applications/TablePro Beta.app/Contents/MacOS/tablepro-mcp"
    static let httpURL = "http://127.0.0.1:23508/mcp"
    static let authorization = "Bearer tp_test"

    // The catalog both apps read lives in the Rust core, six folders above this file.
    static let catalogURL: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
        }
        return url.appendingPathComponent("core/crates/mcp/clients.json")
    }()

    static func catalog() throws -> MCPClientCatalog {
        try MCPClientCatalog.decode(Data(contentsOf: catalogURL))
    }

    struct MissingFixture: Error {
        let id: String
    }

    static func client(_ id: String) throws -> MCPClientDefinition {
        guard let client = try catalog().client(id: id) else { throw MissingFixture(id: id) }
        return client
    }

    static func location(_ id: String, platform: MCPClientPlatform = .macos) throws -> MCPConfigLocation {
        let catalog = try catalog()
        guard let client = catalog.client(id: id), let location = catalog.location(for: client, platform: platform) else {
            throw MissingFixture(id: id)
        }
        return location
    }

    static func target(for platform: MCPClientPlatform) -> MCPServerTarget {
        switch platform {
        case .macos: return .stdio(command: bridge)
        case .linux: return .http(url: httpURL, authorization: authorization)
        }
    }

    static func renderer(for platform: MCPClientPlatform) -> MCPTemplateRenderer {
        MCPTemplateRenderer(serverName: "tablepro", target: target(for: platform))
    }

    static let stdioEntry: JSONValue = .object([
        (key: "command", value: .string(bridge)),
        (key: "args", value: .array([])),
    ])

    static func hasPlaceholder(_ text: String) -> Bool {
        text.range(of: #"\{[A-Za-z|]+\}"#, options: .regularExpression) != nil
    }

    static func parsed(_ text: String) throws -> NSDictionary {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.json5Allowed])
        return try #require(object as? NSDictionary)
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableProMCPClientsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
