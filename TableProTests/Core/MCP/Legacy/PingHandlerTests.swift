import Foundation
@testable import TablePro
import Testing

@Suite("Legacy ping handler")
struct LegacyPingHandlerTests {
    @Test("The handler answers ping for legacy clients only, and needs no scope")
    func handlerIdentity() {
        #expect(PingHandler.method == "ping")
        #expect(PingHandler.requiredScopes.isEmpty)
        #expect(PingHandler.isAvailableToLegacyClients)
        #expect(!PingHandler.isAvailableToModernClients)
    }

    @Test("Ping exists only for legacy clients, so a modern client can never reach it")
    func pingIsLegacyOnly() {
        #expect(MCPLegacyEraAdapter.isLegacyOnly(method: PingHandler.method))
        #expect(!PingHandler.isAvailableToModernClients)
    }

    @Test("Ping answers with an empty result")
    func pingAnswersWithAnEmptyResult() async throws {
        let meta = try MCPLegacyTestSupport.legacyMeta()
        let (context, _) = MCPLegacyTestSupport.context(meta: meta)

        let result = try await PingHandler().handle(params: nil, context: context)

        #expect(result == MCPResult.empty)
        #expect(result.kind == .complete)
        #expect(result.payload.isEmpty)
        #expect(result.cacheHint == nil)
    }

    @Test("Ping ignores whatever params a client sends")
    func pingIgnoresItsParams() async throws {
        let meta = try MCPLegacyTestSupport.legacyMeta()
        let (context, _) = MCPLegacyTestSupport.context(meta: meta)

        let result = try await PingHandler().handle(params: .object(["noise": .bool(true)]), context: context)

        #expect(result == MCPResult.empty)
    }

    @Test("A legacy ping encodes as a bare empty object")
    func pingEncodesAsABareEmptyObject() async throws {
        let meta = try MCPLegacyTestSupport.legacyMeta()
        let (context, _) = MCPLegacyTestSupport.context(meta: meta)

        let result = try await PingHandler().handle(params: nil, context: context)
        let encoded = result.asJsonValue(era: .legacy, serverInfo: MCPMethodRegistry.serverInfo)

        #expect(encoded == .object([:]))
    }

    @Test("Ping answers without writing anything to the transport itself")
    func pingWritesNothingToTheTransport() async throws {
        let meta = try MCPLegacyTestSupport.legacyMeta()
        let (context, sink) = MCPLegacyTestSupport.context(meta: meta)

        _ = try await PingHandler().handle(params: nil, context: context)

        let writes = await sink.jsonWrites.count
        let streams = await sink.sseStreamCount
        let closed = await sink.closed
        #expect(writes == 0)
        #expect(streams == 0)
        #expect(!closed)
    }

    @Test("logging/setLevel is legacy-only and accepts the levels the older revisions defined")
    func legacyLoggingSetLevelIsAccepted() async throws {
        let meta = try MCPLegacyTestSupport.legacyMeta()
        let (context, _) = MCPLegacyTestSupport.context(meta: meta)

        for level in LegacyLoggingSetLevelHandler.supportedLevels {
            let result = try await LegacyLoggingSetLevelHandler()
                .handle(params: .object(["level": .string(level)]), context: context)
            #expect(result == MCPResult.empty)
        }
        #expect(MCPLegacyEraAdapter.isLegacyOnly(method: LegacyLoggingSetLevelHandler.method))
        #expect(!LegacyLoggingSetLevelHandler.isAvailableToModernClients)
    }

    @Test("logging/setLevel refuses a level it does not know")
    func legacyLoggingSetLevelRefusesAnUnknownLevel() async throws {
        let meta = try MCPLegacyTestSupport.legacyMeta()
        let (context, _) = MCPLegacyTestSupport.context(meta: meta)

        let error = await #expect(throws: MCPProtocolError.self) {
            _ = try await LegacyLoggingSetLevelHandler()
                .handle(params: .object(["level": .string("shout")]), context: context)
        }

        #expect(error?.code == JsonRpcErrorCode.invalidParams)
    }

    @Test("logging/setLevel refuses a request with no level at all")
    func legacyLoggingSetLevelRefusesAMissingLevel() async throws {
        let meta = try MCPLegacyTestSupport.legacyMeta()
        let (context, _) = MCPLegacyTestSupport.context(meta: meta)

        let error = await #expect(throws: MCPProtocolError.self) {
            _ = try await LegacyLoggingSetLevelHandler().handle(params: nil, context: context)
        }

        #expect(error?.code == JsonRpcErrorCode.invalidParams)
    }
}
