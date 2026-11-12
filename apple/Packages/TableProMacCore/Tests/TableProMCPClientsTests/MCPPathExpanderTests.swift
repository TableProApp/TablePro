import Foundation
@testable import TableProMCPClients
import Testing

struct MCPPathExpanderTests {
    private let home = "/Users/me"

    @Test("A leading tilde is the home folder")
    func tilde() {
        #expect(MCPPathExpander.expand("~/.cursor/mcp.json", home: home, environment: [:]) == "/Users/me/.cursor/mcp.json")
        #expect(MCPPathExpander.expand("~", home: home, environment: [:]) == "/Users/me")
        #expect(MCPPathExpander.expand("~/x", home: "/Users/me/", environment: [:]) == "/Users/me/x")
        #expect(MCPPathExpander.expand("/a/~/b", home: home, environment: [:]) == "/a/~/b")
    }

    @Test("A set variable wins over its default")
    func variableSet() {
        let path = "${XDG_CONFIG_HOME:-~/.config}/zed/settings.json"
        #expect(MCPPathExpander.expand(path, home: home, environment: ["XDG_CONFIG_HOME": "/xdg"]) == "/xdg/zed/settings.json")
    }

    @Test("An unset or empty variable takes its default, tilde included")
    func variableDefault() {
        let path = "${XDG_CONFIG_HOME:-~/.config}/zed/settings.json"
        #expect(MCPPathExpander.expand(path, home: home, environment: [:]) == "/Users/me/.config/zed/settings.json")
        #expect(MCPPathExpander.expand(path, home: home, environment: ["XDG_CONFIG_HOME": ""]) == "/Users/me/.config/zed/settings.json")
        #expect(MCPPathExpander.expand("${CLAUDE_CONFIG_DIR:-~}/.claude.json", home: home, environment: [:]) == "/Users/me/.claude.json")
        #expect(MCPPathExpander.expand("${CLAUDE_CONFIG_DIR:-~}/.claude.json", home: home, environment: ["CLAUDE_CONFIG_DIR": "/cfg"])
            == "/cfg/.claude.json")
    }

    @Test("A variable without a default expands to nothing when unset")
    func variableWithoutDefault() {
        #expect(MCPPathExpander.expand("/a/${NOPE}/b", home: home, environment: [:]) == "/a//b")
        #expect(MCPPathExpander.expand("/a/${HOME}/b", home: home, environment: ["HOME": "/h"]) == "/a//h/b")
    }

    @Test("Every catalog path expands to an absolute path")
    func catalogPaths() throws {
        let catalog = try MCPClientsFixtures.catalog()
        for set in catalog.configs.values {
            for location in [set.macos, set.linux].compactMap({ $0 }) {
                let expanded = MCPPathExpander.expand(location.path, home: home, environment: [:])
                #expect(expanded.hasPrefix("/"), "\(location.path)")
                #expect(!expanded.contains("$") && !expanded.contains("~"), "\(location.path)")
            }
        }
    }
}
