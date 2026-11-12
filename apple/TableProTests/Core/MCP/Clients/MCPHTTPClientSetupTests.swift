import Foundation
@testable import TablePro
import TableProMCPClients
import Testing

struct MCPHTTPClientSetupTests {
    private let token = "tp_secret0123456789"
    private let masked = "tp_secre\u{2022}\u{2022}\u{2022}\u{2022}"

    private func setup() throws -> MCPHTTPClientSetup {
        MCPHTTPClientSetup(
            catalog: try MCPClientSetupFixture.catalog(),
            context: MCPClientSetupContext(home: "/Users/me", environment: [:], bridgePath: "/Applications/TablePro.app/Contents/MacOS/tablepro-mcp"),
            port: 23_508
        )
    }

    @Test("The token sheet lists the HTTP clients this Mac runs, then Other Client")
    func choices() throws {
        #expect(try setup().choices.map { $0.id } == ["editor", "agent", MCPHTTPClientSetup.otherClientID])
    }

    @Test("The snippet on screen carries the masked token and the copied one the real token")
    func maskedSnippet() throws {
        let setup = try setup()
        let shown = try #require(setup.render(clientID: "editor", token: masked))
        let copied = try #require(setup.render(clientID: "editor", token: token))

        #expect(shown.snippet?.contains(token) == false)
        #expect(shown.snippet?.contains("http://127.0.0.1:23508/mcp") == true)
        #expect(copied.snippet?.contains("Bearer \(token)") == true)
        #expect(copied.displayConfigPath == "~/.editor/mcp.json")
    }

    @Test("A client whose settings file only it writes gets its command, not a snippet")
    func commandForUnwritableFile() throws {
        let rendered = try #require(try setup().render(clientID: "agent", token: token))
        #expect(rendered.snippet == nil)
        #expect(rendered.commandLine?.contains("--header") == true)
        #expect(rendered.commandLine?.contains("Bearer \(token)") == true)
    }
}
