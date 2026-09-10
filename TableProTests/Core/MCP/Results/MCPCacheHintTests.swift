import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("MCPCacheHint")
struct MCPCacheHintTests {
    private let serverInfo = MCPImplementation(name: "tablepro", version: "1.2.3")

    @Test("Exactly the six cacheable operations carry caching hints")
    func cacheableMethodSet() {
        let expected: Set<String> = [
            "server/discover",
            "tools/list",
            "prompts/list",
            "resources/list",
            "resources/templates/list",
            "resources/read"
        ]
        #expect(MCPProtocolDispatcher.cacheableMethods == expected)
        #expect(MCPProtocolDispatcher.cacheableMethods.contains("tools/call") == false)
        #expect(MCPProtocolDispatcher.cacheableMethods.contains("prompts/get") == false)
        #expect(MCPProtocolDispatcher.cacheableMethods.contains("completion/complete") == false)
        #expect(MCPProtocolDispatcher.cacheableMethods.contains("subscriptions/listen") == false)
    }

    @Test("Every handler of a cacheable operation returns a hint of its own")
    func cacheableHandlersReturnHints() async throws {
        let services = MCPProtocolHandlerTestSupport.makeToolServices()
        let discover = try await DiscoverHandler().handle(
            params: nil,
            context: MCPProtocolHandlerTestSupport.makeContext(method: "server/discover")
        )
        let tools = try await ToolsListHandler().handle(
            params: nil,
            context: MCPProtocolHandlerTestSupport.makeContext(method: "tools/list")
        )
        let resources = try await ResourcesListHandler(services: services).handle(
            params: nil,
            context: MCPProtocolHandlerTestSupport.makeContext(
                method: "resources/list",
                principalScopes: [.resourcesRead]
            )
        )

        for result in [discover, tools, resources] {
            let hint = try #require(result.cacheHint)
            #expect(hint.ttlMilliseconds >= 0)
        }
    }

    @Test("A public hint converts seconds to milliseconds")
    func publicHint() {
        let hint = MCPCacheHint.publicFor(seconds: 3_600)
        #expect(hint.ttlMilliseconds == 3_600_000)
        #expect(hint.scope == .publicScope)
        #expect(hint.scope.rawValue == "public")
    }

    @Test("A private hint converts seconds to milliseconds")
    func privateHint() {
        let hint = MCPCacheHint.privateFor(seconds: 300)
        #expect(hint.ttlMilliseconds == 300_000)
        #expect(hint.scope == .privateScope)
        #expect(hint.scope.rawValue == "private")
    }

    @Test("A time to live is never negative")
    func ttlIsNeverNegative() {
        #expect(MCPCacheHint(ttlMilliseconds: -1, scope: .publicScope).ttlMilliseconds == 0)
        #expect(MCPCacheHint.publicFor(seconds: -60).ttlMilliseconds == 0)
        #expect(MCPCacheHint.privateFor(seconds: Int.min / 2_000).ttlMilliseconds == 0)
        #expect(MCPCacheHint.uncacheable.ttlMilliseconds == 0)
        #expect(MCPCacheHint.uncacheable.scope == .privateScope)
    }

    @Test("Applying a hint writes ttlMs and cacheScope")
    func applyWritesBothFields() {
        var fields: [String: JsonValue] = ["tools": .array([])]
        MCPCacheHint.privateFor(seconds: 30).apply(to: &fields)
        #expect(fields["ttlMs"]?.intValue == 30_000)
        #expect(fields["cacheScope"]?.stringValue == "private")
        #expect(fields["tools"] != nil)
    }

    @Test("A modern result serializes its hint next to the payload")
    func modernResultCarriesHint() throws {
        let value = MCPResult
            .complete(["tools": .array([])], cacheHint: .publicFor(seconds: 3_600))
            .asJsonValue(era: .modern, serverInfo: serverInfo)
        #expect(value["ttlMs"]?.intValue == 3_600_000)
        #expect(value["cacheScope"]?.stringValue == "public")
    }

    @Test("A legacy result never serializes a hint")
    func legacyResultDropsHint() throws {
        let value = MCPResult
            .complete(["tools": .array([])], cacheHint: .publicFor(seconds: 3_600))
            .asJsonValue(era: .legacy, serverInfo: serverInfo)
        #expect(value["ttlMs"] == nil)
        #expect(value["cacheScope"] == nil)
    }

    @Test("A result without a hint serializes no cache fields")
    func resultWithoutHint() throws {
        let value = MCPResult
            .complete(["content": .array([])])
            .asJsonValue(era: .modern, serverInfo: serverInfo)
        #expect(value["ttlMs"] == nil)
        #expect(value["cacheScope"] == nil)
    }
}
