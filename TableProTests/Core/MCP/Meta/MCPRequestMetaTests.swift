import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("MCPRequestMeta")
struct MCPRequestMetaTests {
    @Test("A request without _meta at all is invalid params")
    func missingMetaObject() throws {
        let error = try #require(decodeFailure(params: .object(["name": .string("list_tables")])))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
        #expect(error.httpStatus == .badRequest)
    }

    @Test("A request missing the protocol version is invalid params")
    func missingProtocolVersion() throws {
        let params = JsonValue.object([
            "_meta": .object([MCPMetaKeys.clientCapabilities: .object([:])])
        ])
        let error = try #require(decodeFailure(params: params))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
        #expect(error.httpStatus == .badRequest)
        #expect(error.message.contains(MCPMetaKeys.protocolVersion))
    }

    @Test("An empty protocol version string is invalid params")
    func emptyProtocolVersion() throws {
        let params = JsonValue.object([
            "_meta": .object([
                MCPMetaKeys.protocolVersion: .string(""),
                MCPMetaKeys.clientCapabilities: .object([:])
            ])
        ])
        let error = try #require(decodeFailure(params: params))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test("A request missing client capabilities is invalid params")
    func missingClientCapabilities() throws {
        let params = JsonValue.object([
            "_meta": .object([MCPMetaKeys.protocolVersion: .string(MCPProtocolVersion.latest.rawValue)])
        ])
        let error = try #require(decodeFailure(params: params))
        #expect(error.code == JsonRpcErrorCode.invalidParams)
        #expect(error.httpStatus == .badRequest)
        #expect(error.message.contains(MCPMetaKeys.clientCapabilities))
    }

    @Test("Client capabilities that are not an object are invalid params")
    func nonObjectClientCapabilities() throws {
        for value in [JsonValue.null, .string("none"), .array([]), .bool(true)] {
            let params = JsonValue.object([
                "_meta": .object([
                    MCPMetaKeys.protocolVersion: .string(MCPProtocolVersion.latest.rawValue),
                    MCPMetaKeys.clientCapabilities: value
                ])
            ])
            let error = try #require(decodeFailure(params: params))
            #expect(error.code == JsonRpcErrorCode.invalidParams)
        }
    }

    @Test("An unsupported protocol version reports the supported and requested versions")
    func unsupportedProtocolVersion() throws {
        let error = try #require(decodeFailure(params: params(version: "1999-01-01")))
        #expect(error.code == JsonRpcErrorCode.unsupportedProtocolVersion)
        #expect(error.code == -32_022)
        #expect(error.httpStatus == .badRequest)
        #expect(error.data?["requested"]?.stringValue == "1999-01-01")

        let supportedValues = try #require(error.data?["supported"]?.arrayValue)
        #expect(supportedValues.compactMap(\.stringValue) == MCPProtocolVersion.supportedRawValues)
    }

    @Test("2025-03-26 is not a supported protocol version")
    func draftVersionIsNotSupported() throws {
        let retired = MCPProtocolVersion("2025-03-26")
        #expect(retired.isSupported == false)
        #expect(MCPProtocolVersion.supported.contains(retired) == false)
        #expect(MCPProtocolVersion.supportedRawValues.contains("2025-03-26") == false)

        let error = try #require(decodeFailure(params: params(version: "2025-03-26")))
        #expect(error.code == JsonRpcErrorCode.unsupportedProtocolVersion)
        #expect(error.data?["requested"]?.stringValue == "2025-03-26")
    }

    @Test("Every advertised version decodes and reports its own era")
    func everySupportedVersionDecodes() throws {
        for raw in MCPProtocolVersion.supportedRawValues {
            let meta = try MCPRequestMeta.decodeModern(params: params(version: raw))
            #expect(meta.protocolVersion.rawValue == raw)
            #expect(meta.era == MCPProtocolVersion(raw).era)
        }
        #expect(MCPProtocolVersion.latest.era == .modern)
        #expect(MCPProtocolVersion.v20251125.era == .legacy)
        #expect(MCPProtocolVersion.v20250618.era == .legacy)
    }

    @Test("A string progress token is accepted")
    func stringProgressToken() throws {
        let meta = try MCPRequestMeta.decodeModern(params: params(progressToken: .string("abc-123")))
        #expect(meta.progressToken == .string("abc-123"))
    }

    @Test("An integer progress token is accepted")
    func integerProgressToken() throws {
        let meta = try MCPRequestMeta.decodeModern(params: params(progressToken: .int(42)))
        #expect(meta.progressToken == .number(42))
    }

    @Test("A progress token that is neither a string nor an integer is rejected")
    func rejectsNonScalarProgressToken() throws {
        let rejected: [JsonValue] = [
            .double(1.5),
            .bool(true),
            .object(["token": .string("x")]),
            .array([.string("x")])
        ]
        for value in rejected {
            let error = try #require(decodeFailure(params: params(progressToken: value)))
            #expect(error.code == JsonRpcErrorCode.invalidParams)
            #expect(error.message.contains("progressToken"))
        }
    }

    @Test("A null progress token means no progress token")
    func nullProgressToken() throws {
        let meta = try MCPRequestMeta.decodeModern(params: params(progressToken: .null))
        #expect(meta.progressToken == nil)
    }

    @Test("An absent progress token means no progress token")
    func absentProgressToken() throws {
        let meta = try MCPRequestMeta.decodeModern(params: params())
        #expect(meta.progressToken == nil)
    }

    @Test("traceparent, tracestate and baggage are read unprefixed")
    func readsTraceContext() throws {
        let traceparent = "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01"
        var fields = MCPProtocolTestSupport.metaFields()
        fields[MCPMetaKeys.traceParent] = .string(traceparent)
        fields[MCPMetaKeys.traceState] = .string("vendor=value")
        fields[MCPMetaKeys.baggage] = .string("userId=42")
        fields["com.example/other"] = .string("ignored")

        let meta = try MCPRequestMeta.decodeModern(params: .object(["_meta": .object(fields)]))
        #expect(meta.traceContext[MCPMetaKeys.traceParent] == traceparent)
        #expect(meta.traceContext[MCPMetaKeys.traceState] == "vendor=value")
        #expect(meta.traceContext[MCPMetaKeys.baggage] == "userId=42")
        #expect(meta.traceContext["com.example/other"] == nil)
        #expect(meta.traceContext.count == 3)
    }

    @Test("Client info is decoded when present and absent otherwise")
    func decodesClientInfo() throws {
        let meta = try MCPRequestMeta.decodeModern(params: params())
        #expect(meta.clientInfo?.name == "TestClient")

        var fields = MCPProtocolTestSupport.metaFields(clientName: nil)
        fields[MCPMetaKeys.clientInfo] = nil
        let anonymous = try MCPRequestMeta.decodeModern(params: .object(["_meta": .object(fields)]))
        #expect(anonymous.clientInfo == nil)
    }

    @Test("Declared client capabilities survive decoding")
    func decodesClientCapabilities() throws {
        let capabilities = JsonValue.object([
            "elicitation": .object(["modes": .array([.string("form"), .string("url")])]),
            "sampling": .object([:])
        ])
        let meta = try MCPRequestMeta.decodeModern(params: params(capabilities: capabilities))
        #expect(meta.clientCapabilities.supportsElicitation)
        #expect(meta.clientCapabilities.supportsSampling)
        #expect(meta.clientCapabilities.supportsRoots == false)
        #expect(meta.clientCapabilities.supportsElicitationMode("url"))
        #expect(meta.clientCapabilities.supportsElicitationMode("chat") == false)
    }

    @Test("declaresModernProtocol only reports true when the version key is a string")
    func declaresModernProtocol() {
        #expect(MCPRequestMeta.declaresModernProtocol(params: params()))
        #expect(MCPRequestMeta.declaresModernProtocol(params: params(version: "2025-11-25")))
        #expect(MCPRequestMeta.declaresModernProtocol(params: nil) == false)
        #expect(MCPRequestMeta.declaresModernProtocol(params: .object([:])) == false)
        #expect(MCPRequestMeta.declaresModernProtocol(params: .object(["_meta": .object([:])])) == false)
        let numericVersion = JsonValue.object(["_meta": .object([MCPMetaKeys.protocolVersion: .int(2026)])])
        #expect(MCPRequestMeta.declaresModernProtocol(params: numericVersion) == false)
    }

    @Test("A synthesized legacy meta keeps the negotiated version and the request progress token")
    func synthesizedLegacy() throws {
        let params = JsonValue.object([
            "_meta": .object([
                MCPMetaKeys.progressToken: .string("legacy-token"),
                MCPMetaKeys.traceParent: .string("00-trace-parent-01")
            ])
        ])
        let meta = try MCPRequestMeta.synthesizedLegacy(
            protocolVersion: .v20250618,
            clientInfo: MCPImplementation(name: "OldClient", version: "0.9"),
            clientCapabilities: MCPClientCapabilities(json: .object(["roots": .object([:])])),
            params: params
        )
        #expect(meta.protocolVersion == .v20250618)
        #expect(meta.era == .legacy)
        #expect(meta.progressToken == .string("legacy-token"))
        #expect(meta.clientInfo?.name == "OldClient")
        #expect(meta.clientCapabilities.supportsRoots)
        #expect(meta.traceContext[MCPMetaKeys.traceParent] == "00-trace-parent-01")
    }

    @Test("A legacy request with an unusable progress token is rejected too")
    func synthesizedLegacyRejectsBadProgressToken() throws {
        let params = JsonValue.object(["_meta": .object([MCPMetaKeys.progressToken: .double(2.5)])])
        var thrown: MCPProtocolError?
        do {
            _ = try MCPRequestMeta.synthesizedLegacy(
                protocolVersion: .v20251125,
                clientInfo: nil,
                clientCapabilities: .none,
                params: params
            )
        } catch let error as MCPProtocolError {
            thrown = error
        }
        let error = try #require(thrown)
        #expect(error.code == JsonRpcErrorCode.invalidParams)
    }

    @Test("metaObject reads the _meta object out of the params")
    func metaObjectLookup() {
        #expect(MCPRequestMeta.metaObject(in: nil) == nil)
        #expect(MCPRequestMeta.metaObject(in: .object([:])) == nil)
        #expect(MCPRequestMeta.metaObject(in: .string("nope")) == nil)
        let meta = MCPRequestMeta.metaObject(in: .object(["_meta": .object(["a": .int(1)])]))
        #expect(meta?["a"]?.intValue == 1)
    }

    private func params(
        version: String = MCPProtocolVersion.latest.rawValue,
        capabilities: JsonValue = .object([:]),
        progressToken: JsonValue? = nil
    ) -> JsonValue {
        var fields = MCPProtocolTestSupport.metaFields(
            protocolVersion: MCPProtocolVersion(version),
            clientCapabilities: capabilities,
            progressToken: progressToken
        )
        if progressToken == nil {
            fields[MCPMetaKeys.progressToken] = nil
        }
        return .object(["_meta": .object(fields)])
    }

    private func decodeFailure(params: JsonValue?) -> MCPProtocolError? {
        do {
            _ = try MCPRequestMeta.decodeModern(params: params)
            return nil
        } catch let error as MCPProtocolError {
            return error
        } catch {
            return nil
        }
    }
}

@Suite("MCPMetaKeys")
struct MCPMetaKeysTests {
    @Test("The reserved protocol keys carry the io.modelcontextprotocol prefix")
    func reservedKeySpellings() {
        #expect(MCPMetaKeys.protocolVersion == "io.modelcontextprotocol/protocolVersion")
        #expect(MCPMetaKeys.clientInfo == "io.modelcontextprotocol/clientInfo")
        #expect(MCPMetaKeys.clientCapabilities == "io.modelcontextprotocol/clientCapabilities")
        #expect(MCPMetaKeys.logLevel == "io.modelcontextprotocol/logLevel")
        #expect(MCPMetaKeys.subscriptionId == "io.modelcontextprotocol/subscriptionId")
        #expect(MCPMetaKeys.serverInfo == "io.modelcontextprotocol/serverInfo")
        #expect(MCPMetaKeys.progressToken == "progressToken")
    }

    @Test("A prefix whose second label is modelcontextprotocol or mcp is reserved")
    func reservedPrefixes() {
        #expect(MCPMetaKeys.isReserved(key: "io.modelcontextprotocol/protocolVersion"))
        #expect(MCPMetaKeys.isReserved(key: "org.modelcontextprotocol.api/thing"))
        #expect(MCPMetaKeys.isReserved(key: "com.mcp.tools/thing"))
        #expect(MCPMetaKeys.isReserved(key: "dev.mcp/thing"))
        #expect(MCPMetaKeys.isReserved(key: "IO.ModelContextProtocol/thing"))
    }

    @Test("com.example.mcp is not reserved because its second label is example")
    func vendorPrefixWithMcpTailIsNotReserved() {
        #expect(MCPMetaKeys.isReserved(key: "com.example.mcp/thing") == false)
        #expect(MCPMetaKeys.isReserved(key: "com.example/thing") == false)
        #expect(MCPMetaKeys.isReserved(key: "app.tablepro.mcp/thing") == false)
    }

    @Test("An unprefixed key is never reserved by the prefix rule")
    func unprefixedKeysAreNotReservedByPrefix() {
        #expect(MCPMetaKeys.isReserved(key: "progressToken") == false)
        #expect(MCPMetaKeys.isReserved(key: "traceparent") == false)
        #expect(MCPMetaKeys.isReserved(key: "mcp/thing") == false)
    }

    @Test("traceparent, tracestate and baggage are valid without a prefix")
    func traceContextKeysAreValid() {
        #expect(MCPMetaKeys.isValid(key: "traceparent"))
        #expect(MCPMetaKeys.isValid(key: "tracestate"))
        #expect(MCPMetaKeys.isValid(key: "baggage"))
        #expect(MCPMetaKeys.traceContextKeys == ["traceparent", "tracestate", "baggage"])
    }

    @Test("A well formed prefix and name is valid")
    func validKeys() {
        #expect(MCPMetaKeys.isValid(key: "progressToken"))
        #expect(MCPMetaKeys.isValid(key: MCPMetaKeys.protocolVersion))
        #expect(MCPMetaKeys.isValid(key: "com.example/thing"))
        #expect(MCPMetaKeys.isValid(key: "com.example-1/a_b.c-9"))
        #expect(MCPMetaKeys.isValid(key: "com.example/"))
    }

    @Test("A malformed prefix or name is rejected")
    func invalidKeys() {
        #expect(MCPMetaKeys.isValid(key: "1com.example/thing") == false)
        #expect(MCPMetaKeys.isValid(key: "com.-example/thing") == false)
        #expect(MCPMetaKeys.isValid(key: "com.example./thing") == false)
        #expect(MCPMetaKeys.isValid(key: "/thing") == false)
        #expect(MCPMetaKeys.isValid(key: "com.example//thing") == false)
        #expect(MCPMetaKeys.isValid(key: "com.example/-thing") == false)
        #expect(MCPMetaKeys.isValid(key: "com.example/thing-") == false)
        #expect(MCPMetaKeys.isValid(key: "com.example/thing!") == false)
    }
}
