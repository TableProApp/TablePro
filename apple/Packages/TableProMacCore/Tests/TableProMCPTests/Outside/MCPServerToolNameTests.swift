import Foundation
@testable import TableProMCP
import Testing

struct MCPServerToolNameTests {
    private let server = MCPServerConfiguration(
        name: "Runbooks",
        endpoint: URL(string: "https://a.example/mcp") ?? URL(fileURLWithPath: "/")
    )

    private func isAcceptedByProviders(_ name: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return !name.isEmpty
            && name.count <= MCPServerConfiguration.maxToolNameLength
            && name.allSatisfy { allowed.contains($0) }
    }

    @Test("A short plain name is kept after the namespace")
    func shortNameIsKept() {
        #expect(server.toolName(for: "search") == server.toolNamespace + "search")
        #expect(isAcceptedByProviders(server.toolName(for: "search")))
    }

    @Test("A 26 character name still fits whole")
    func longestWholeNameFits() {
        let name = "create_pull_request_review"
        #expect(server.toolName(for: name) == server.toolNamespace + name)
        #expect(server.toolName(for: name).count == 64)
    }

    @Test(
        "Any remote name becomes one a provider accepts",
        arguments: [
            "create_pull_request_review_comment",
            "repo.search",
            "files/read",
            "tìm kiếm",
            "a b c",
            "",
            String(repeating: "x", count: 300)
        ]
    )
    func everyNameIsAccepted(remoteName: String) {
        let name = server.toolName(for: remoteName)
        #expect(isAcceptedByProviders(name))
        #expect(name.hasPrefix(server.toolNamespace))
    }

    @Test("The same remote name always maps to the same name")
    func aliasIsStable() {
        let first = server.toolName(for: "repo.search")
        let second = server.toolName(for: "repo.search")
        #expect(first == second)
    }

    @Test("Names that differ only in a replaced character or past the cut stay distinct")
    func foldedNamesStayDistinct() {
        #expect(server.toolName(for: "repo.search") != server.toolName(for: "repo/search"))
        #expect(server.toolName(for: "repo.search") != server.toolName(for: "repo_search"))
        let long = String(repeating: "x", count: 40)
        #expect(server.toolName(for: long + "a") != server.toolName(for: long + "b"))
    }
}
