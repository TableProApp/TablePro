import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("MCPResult")
struct MCPResultTests {
    private let serverInfo = MCPImplementation(name: "tablepro", title: "TablePro", version: "1.2.3")

    @Test("A modern result declares resultType complete")
    func modernResultDeclaresResultType() throws {
        let value = MCPResult
            .complete(["tools": .array([])])
            .asJsonValue(era: .modern, serverInfo: serverInfo)
        #expect(value["resultType"]?.stringValue == "complete")
        #expect(value["tools"]?.arrayValue?.isEmpty == true)
    }

    @Test("An interim result declares resultType input_required")
    func interimResultDeclaresResultType() throws {
        let result = MCPResult(kind: .inputRequired, payload: ["inputRequests": .array([])])
        let value = result.asJsonValue(era: .modern, serverInfo: serverInfo)
        #expect(value["resultType"]?.stringValue == "input_required")
        #expect(MCPResult.Kind.inputRequired.rawValue == "input_required")
    }

    @Test("A legacy projection carries no resultType, no cache fields and no serverInfo")
    func legacyProjectionIsBare() throws {
        let result = MCPResult.complete(
            ["tools": .array([])],
            cacheHint: .publicFor(seconds: 300)
        )
        let value = result.asJsonValue(era: .legacy, serverInfo: serverInfo)

        #expect(value["resultType"] == nil)
        #expect(value["ttlMs"] == nil)
        #expect(value["cacheScope"] == nil)
        #expect(value["_meta"] == nil)
        #expect(value["tools"] != nil)
    }

    @Test("Server info lands in _meta for a modern result and never at the top level")
    func serverInfoLivesInMeta() throws {
        let value = MCPResult.complete([:]).asJsonValue(era: .modern, serverInfo: serverInfo)

        #expect(value["serverInfo"] == nil)
        let meta = try #require(value["_meta"])
        let carried = try #require(meta[MCPMetaKeys.serverInfo])
        #expect(carried["name"]?.stringValue == "tablepro")
        #expect(carried["version"]?.stringValue == "1.2.3")
        #expect(carried["title"]?.stringValue == "TablePro")
    }

    @Test("A legacy result never carries server info in _meta")
    func legacyResultOmitsServerInfo() throws {
        var result = MCPResult.complete(["ok": .bool(true)])
        result.meta.serverInfo = serverInfo
        let value = result.asJsonValue(era: .legacy, serverInfo: serverInfo)

        #expect(value["_meta"] == nil)
        #expect(value["serverInfo"] == nil)
        #expect(value["ok"]?.boolValue == true)
    }

    @Test("A handler that sets its own server info keeps it")
    func handlerServerInfoWins() throws {
        var result = MCPResult.complete([:])
        result.meta.serverInfo = MCPImplementation(name: "handler-chosen", version: "9.9.9")
        let value = result.asJsonValue(era: .modern, serverInfo: serverInfo)

        let carried = try #require(value["_meta"]?[MCPMetaKeys.serverInfo])
        #expect(carried["name"]?.stringValue == "handler-chosen")
    }

    @Test("A subscription id is carried in _meta for both eras")
    func subscriptionIdIsCarried() throws {
        var result = MCPResult.complete([:])
        result.meta.subscriptionId = .string("sub-7")

        let modern = result.asJsonValue(era: .modern, serverInfo: serverInfo)
        #expect(modern["_meta"]?[MCPMetaKeys.subscriptionId]?.stringValue == "sub-7")

        let legacy = result.asJsonValue(era: .legacy, serverInfo: serverInfo)
        #expect(legacy["_meta"]?[MCPMetaKeys.subscriptionId]?.stringValue == "sub-7")
        #expect(legacy["_meta"]?[MCPMetaKeys.serverInfo] == nil)
    }

    @Test("Passthrough metadata survives serialization")
    func passthroughMetaSurvives() throws {
        var result = MCPResult.complete([:])
        result.meta.passthrough["com.example/trace"] = .string("abc")
        let value = result.asJsonValue(era: .modern, serverInfo: serverInfo)
        #expect(value["_meta"]?["com.example/trace"]?.stringValue == "abc")
    }

    @Test("A modern result with no metadata at all still omits an empty _meta")
    func emptyMetaIsOmitted() throws {
        let value = MCPResult.complete(["ok": .bool(true)]).asJsonValue(era: .modern, serverInfo: nil)
        #expect(value["_meta"] == nil)
        #expect(value["resultType"]?.stringValue == "complete")
    }

    @Test("The payload is copied through untouched")
    func payloadIsPreserved() throws {
        let payload: [String: JsonValue] = [
            "contents": .array([.object(["uri": .string("tablepro://connections")])]),
            "nextCursor": .string("cursor-1")
        ]
        let value = MCPResult.complete(payload).asJsonValue(era: .modern, serverInfo: serverInfo)
        #expect(value["nextCursor"]?.stringValue == "cursor-1")
        #expect(value["contents"]?.arrayValue?.count == 1)
    }

    @Test("The empty result is a complete result with no payload")
    func emptyResult() {
        #expect(MCPResult.empty.kind == .complete)
        #expect(MCPResult.empty.payload.isEmpty)
        #expect(MCPResult.empty.cacheHint == nil)
        #expect(MCPResult.empty.meta.isEmpty)
    }

    @Test("A result defaults to complete with no cache hint")
    func defaultsAreComplete() {
        let result = MCPResult()
        #expect(result.kind == .complete)
        #expect(result.cacheHint == nil)
        #expect(result.meta.isEmpty)
    }

    @Test("Result metadata reports emptiness from its own fields")
    func resultMetaEmptiness() {
        #expect(MCPResultMeta().isEmpty)
        #expect(MCPResultMeta(serverInfo: serverInfo).isEmpty == false)
        #expect(MCPResultMeta(subscriptionId: .number(1)).isEmpty == false)
        #expect(MCPResultMeta(passthrough: ["a": .int(1)]).isEmpty == false)
        #expect(MCPResultMeta().asJsonValue(era: .modern) == nil)
    }
}
