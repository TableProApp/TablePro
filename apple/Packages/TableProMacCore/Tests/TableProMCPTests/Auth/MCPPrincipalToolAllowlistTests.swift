import Foundation
import TableProMCP
import Testing

struct MCPPrincipalToolAllowlistTests {
    private let tokenId = UUID()

    private func principal(toolAllowlist: Set<String>? = nil) -> MCPPrincipal {
        MCPPrincipal(
            tokenFingerprint: "fp",
            tokenId: tokenId,
            scopes: [.toolsRead],
            metadata: MCPPrincipalMetadata(label: "test", issuedAt: Date(timeIntervalSince1970: 0), expiresAt: nil),
            toolAllowlist: toolAllowlist
        )
    }

    @Test("A principal without an allowlist allows every tool its scopes reach")
    func noAllowlistAllowsEveryTool() {
        let open = principal()

        #expect(open.toolAllowlist == nil)
        #expect(open.allowsTool("list_tables"))
        #expect(open.allowsTool("execute_query"))
    }

    @Test("An allowlist allows only the tools it names")
    func allowlistIsMembership() {
        let narrow = principal(toolAllowlist: ["list_tables", "describe_table"])

        #expect(narrow.allowsTool("list_tables"))
        #expect(narrow.allowsTool("describe_table"))
        #expect(!narrow.allowsTool("execute_query"))
        #expect(!narrow.allowsTool(""))
    }

    @Test("An empty allowlist allows no tool")
    func emptyAllowlistAllowsNothing() {
        #expect(!principal(toolAllowlist: []).allowsTool("list_tables"))
    }

    @Test("Two principals differing only in their allowlist are not equal")
    func equalityIncludesTheAllowlist() {
        let tables = principal(toolAllowlist: ["list_tables"])
        let sameTables = principal(toolAllowlist: ["list_tables"])

        #expect(principal() != tables)
        #expect(tables != principal(toolAllowlist: ["describe_table"]))
        #expect(tables == sameTables)
    }

    @Test("The in-app assistant carries no allowlist")
    func inAppAssistantIsUnrestricted() {
        #expect(MCPPrincipal.inAppAssistant.toolAllowlist == nil)
    }
}
