import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("DiscoverHandler")
struct DiscoverHandlerTests {
    @Test("The handler answers server/discover")
    func methodName() {
        #expect(DiscoverHandler.method == "server/discover")
    }

    @Test("Discovery requires no scopes so a client can probe before it holds any")
    func requiresNoScopes() async throws {
        #expect(DiscoverHandler.requiredScopes.isEmpty)

        let context = await MCPProtocolHandlerTestSupport.makeContext(
            method: "server/discover",
            principalScopes: []
        )
        let result = try await DiscoverHandler().handle(params: nil, context: context)
        #expect(result.kind == .complete)
    }

    @Test("Discovery is a modern operation and is not offered to legacy clients")
    func modernOnly() {
        #expect(DiscoverHandler.isAvailableToLegacyClients == false)
    }

    @Test("Supported versions match the versions the server advertises")
    func supportedVersions() async throws {
        let result = try await discover()
        let versions = try #require(result.payload["supportedVersions"]?.arrayValue)
        #expect(versions.compactMap(\.stringValue) == MCPProtocolVersion.supportedRawValues)
        #expect(versions.first?.stringValue == MCPProtocolVersion.latest.rawValue)
        #expect(versions.compactMap(\.stringValue).contains("2025-03-26") == false)
    }

    @Test("Capabilities are reported")
    func capabilitiesArePresent() async throws {
        let result = try await discover()
        let capabilities = try #require(result.payload["capabilities"])
        #expect(capabilities["tools"] != nil)
        #expect(capabilities["resources"] != nil)
        #expect(capabilities["resources"]?["subscribe"]?.boolValue == true)
        #expect(capabilities["prompts"] != nil)
        #expect(capabilities["completions"] != nil)
        #expect(capabilities["extensions"] != nil)
    }

    @Test("A legacy era projection reports resources without subscribe")
    func legacyCapabilities() async throws {
        let context = await MCPProtocolHandlerTestSupport.makeContext(
            method: "server/discover",
            era: .legacy
        )
        let result = try await DiscoverHandler().handle(params: nil, context: context)
        let capabilities = try #require(result.payload["capabilities"])
        #expect(capabilities["resources"]?["subscribe"]?.boolValue == false)
        #expect(capabilities["extensions"] == nil)
    }

    @Test("Instructions are non-empty guidance for the model")
    func instructionsArePresent() async throws {
        let result = try await discover()
        let instructions = try #require(result.payload["instructions"]?.stringValue)
        #expect(instructions.isEmpty == false)
        #expect(instructions == MCPMethodRegistry.instructions)
    }

    @Test("Server info is carried in _meta, never at the top level")
    func serverInfoIsInMeta() async throws {
        let result = try await discover()
        #expect(result.payload["serverInfo"] == nil)
        #expect(result.meta.serverInfo?.name == MCPMethodRegistry.serverInfo.name)

        let value = result.asJsonValue(era: .modern, serverInfo: MCPMethodRegistry.serverInfo)
        #expect(value["serverInfo"] == nil)
        let carried = try #require(value["_meta"]?[MCPMetaKeys.serverInfo])
        #expect(carried["name"]?.stringValue == "tablepro")
    }

    @Test("The result is cacheable and publicly shareable")
    func resultIsCacheable() async throws {
        let result = try await discover()
        let hint = try #require(result.cacheHint)
        #expect(hint.scope == .publicScope)
        #expect(hint.ttlMilliseconds == 3_600_000)
        #expect(MCPProtocolDispatcher.cacheableMethods.contains(DiscoverHandler.method))

        let value = result.asJsonValue(era: .modern, serverInfo: MCPMethodRegistry.serverInfo)
        #expect(value["ttlMs"]?.intValue == 3_600_000)
        #expect(value["cacheScope"]?.stringValue == "public")
        #expect(value["resultType"]?.stringValue == "complete")
    }

    @Test("Discovery ignores whatever params it is handed")
    func ignoresParams() async throws {
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "server/discover")
        let noisy = JsonValue.object(["unexpected": .string("value")])
        let result = try await DiscoverHandler().handle(params: noisy, context: context)
        #expect(result.payload["supportedVersions"] != nil)
    }

    private func discover() async throws -> MCPResult {
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "server/discover")
        return try await DiscoverHandler().handle(params: nil, context: context)
    }
}
