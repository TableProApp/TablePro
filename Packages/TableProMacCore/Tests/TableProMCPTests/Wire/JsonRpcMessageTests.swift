import Foundation
@testable import TableProMCP
import Testing

struct JsonRpcMessageTests {
    @Test func testRequestRoundTrip() throws {
        let message = JsonRpcMessage.request(
            JsonRpcRequest(
                id: .number(1),
                method: "tools/list",
                params: .object(["cursor": .string("abc")])
            )
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        #expect(decoded == message)
    }

    @Test func testRequestWithoutParamsRoundTrip() throws {
        let message = JsonRpcMessage.request(
            JsonRpcRequest(id: .string("req-1"), method: "ping", params: nil)
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        #expect(decoded == message)

        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"params\""))
    }

    @Test func testNotificationRoundTrip() throws {
        let message = JsonRpcMessage.notification(
            JsonRpcNotification(method: "notifications/initialized", params: nil)
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        #expect(decoded == message)

        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"id\""))
        #expect(!json.contains("\"params\""))
    }

    @Test func testNotificationWithParamsRoundTrip() throws {
        let message = JsonRpcMessage.notification(
            JsonRpcNotification(
                method: "notifications/progress",
                params: .object(["progress": .int(50)])
            )
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        #expect(decoded == message)
    }

    @Test func testSuccessResponseRoundTrip() throws {
        let message = JsonRpcMessage.successResponse(
            JsonRpcSuccessResponse(
                id: .number(7),
                result: .object(["tools": .array([])])
            )
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        #expect(decoded == message)
    }

    @Test func testErrorResponseRoundTrip() throws {
        let message = JsonRpcMessage.errorResponse(
            JsonRpcErrorResponse(
                id: .number(8),
                error: JsonRpcError.methodNotFound(message: "not here")
            )
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        #expect(decoded == message)
    }

    @Test func testErrorResponseWithNullIdEncodesAsJsonNull() throws {
        let message = JsonRpcMessage.errorResponse(
            JsonRpcErrorResponse(id: nil, error: JsonRpcError.parseError())
        )
        let data = try JsonRpcCodec.encode(message)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"id\":null"))
    }

    @Test func testErrorResponseWithExplicitNullIdRoundTrips() throws {
        let message = JsonRpcMessage.errorResponse(
            JsonRpcErrorResponse(id: .null, error: JsonRpcError.serverError())
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        if case .errorResponse(let response) = decoded {
            #expect(response.id == .null)
        } else {
            Issue.record("Expected errorResponse")
        }
    }

    @Test func testErrorResponseDataRoundTrip() throws {
        let message = JsonRpcMessage.errorResponse(
            JsonRpcErrorResponse(
                id: .number(9),
                error: JsonRpcError(
                    code: JsonRpcErrorCode.forbidden,
                    message: "no access",
                    data: .object(["reason": .string("policy")])
                )
            )
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        #expect(decoded == message)
    }

    @Test func testErrorResponseWithoutDataOmitsField() throws {
        let message = JsonRpcMessage.errorResponse(
            JsonRpcErrorResponse(
                id: .number(10),
                error: JsonRpcError.methodNotFound()
            )
        )
        let data = try JsonRpcCodec.encode(message)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"data\""))
    }

    @Test func testRejectsNon20JsonRpcVersion() {
        let raw = Data(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#.utf8)
        if let error = #expect(throws: (any Error).self, performing: { try JsonRpcCodec.decode(raw) }) {
            guard case JsonRpcDecodingError.invalidJsonRpcVersion(let value) = error else {
                Issue.record("Expected invalidJsonRpcVersion, got \(error)")
                return
            }
            #expect(value == "1.0")
        }
    }

    @Test func testRejectsMissingJsonRpcVersion() {
        let raw = Data(#"{"id":1,"method":"ping"}"#.utf8)
        if let error = #expect(throws: (any Error).self, performing: { try JsonRpcCodec.decode(raw) }) {
            #expect(error as? JsonRpcDecodingError == .missingJsonRpcVersion)
        }
    }

    @Test func testRejectsBatchArray() {
        let raw = Data(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#.utf8)
        if let error = #expect(throws: (any Error).self, performing: { try JsonRpcCodec.decode(raw) }) {
            #expect(error as? JsonRpcDecodingError == .batchUnsupported)
        }
    }

    @Test func testRejectsBatchArrayWithLeadingWhitespace() {
        let raw = Data("   \n[{\"jsonrpc\":\"2.0\"}]".utf8)
        if let error = #expect(throws: (any Error).self, performing: { try JsonRpcCodec.decode(raw) }) {
            #expect(error as? JsonRpcDecodingError == .batchUnsupported)
        }
    }

    @Test func testEncodeLineAppendsNewline() throws {
        let message = JsonRpcMessage.notification(
            JsonRpcNotification(method: "ping", params: nil)
        )
        let data = try JsonRpcCodec.encodeLine(message)
        #expect(data.last == 0x0A)
    }

    @Test func testNullIdInRequestRoundTrips() throws {
        let message = JsonRpcMessage.request(
            JsonRpcRequest(id: .null, method: "test", params: nil)
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        #expect(decoded == message)
    }

    @Test func testRejectsAmbiguousMessageWithMethodAndResult() {
        let raw = Data(#"{"jsonrpc":"2.0","id":1,"method":"foo","result":1}"#.utf8)
        if let error = #expect(throws: (any Error).self, performing: { try JsonRpcCodec.decode(raw) }) {
            #expect(error as? JsonRpcDecodingError == .ambiguousMessage)
        }
    }

    @Test func testRejectsResultAndError() {
        let raw = Data(#"{"jsonrpc":"2.0","id":1,"result":1,"error":{"code":-32000,"message":"x"}}"#.utf8)
        if let error = #expect(throws: (any Error).self, performing: { try JsonRpcCodec.decode(raw) }) {
            #expect(error as? JsonRpcDecodingError == .ambiguousMessage)
        }
    }

    @Test func testRejectsEmptyEnvelope() {
        let raw = Data(#"{"jsonrpc":"2.0","id":1}"#.utf8)
        if let error = #expect(throws: (any Error).self, performing: { try JsonRpcCodec.decode(raw) }) {
            #expect(error as? JsonRpcDecodingError == .missingResultOrError)
        }
    }

    @Test func testRejectsEnvelopeWithoutMethodOrIdEvenWithVersion() {
        let raw = Data(#"{"jsonrpc":"2.0"}"#.utf8)
        if let error = #expect(throws: (any Error).self, performing: { try JsonRpcCodec.decode(raw) }) {
            #expect(error as? JsonRpcDecodingError == .missingMethod)
        }
    }

    @Test func testSpecificationErrorCodesSurviveARoundTrip() throws {
        for code in [
            JsonRpcErrorCode.headerMismatch,
            JsonRpcErrorCode.missingRequiredClientCapability,
            JsonRpcErrorCode.unsupportedProtocolVersion
        ] {
            let message = JsonRpcMessage.errorResponse(
                JsonRpcErrorResponse(id: .number(1), error: JsonRpcError(code: code, message: "x"))
            )
            let decoded = try JsonRpcCodec.decode(try JsonRpcCodec.encode(message))
            #expect(decoded == message, "code \(code) must survive the wire")
        }
    }

    @Test func testUnsupportedProtocolVersionDataRoundTrips() throws {
        let payload = JsonValue.object([
            "supported": .array(MCPProtocolVersion.supportedRawValues.map { .string($0) }),
            "requested": .string("1999-01-01")
        ])
        let message = JsonRpcMessage.errorResponse(
            JsonRpcErrorResponse(
                id: .number(2),
                error: JsonRpcError(
                    code: JsonRpcErrorCode.unsupportedProtocolVersion,
                    message: "Unsupported protocol version",
                    data: payload
                )
            )
        )
        let decoded = try JsonRpcCodec.decode(try JsonRpcCodec.encode(message))
        guard case .errorResponse(let response) = decoded else {
            Issue.record("Expected errorResponse")
            return
        }
        #expect(response.error.data?["supported"]?.arrayValue?.compactMap(\.stringValue) == MCPProtocolVersion.supportedRawValues)
    }

    @Test func testRequestMetaSurvivesTheWire() throws {
        let params = JsonValue.object([
            "name": .string("run_query"),
            "_meta": .object([
                MCPMetaKeys.protocolVersion: .string(MCPProtocolVersion.latest.rawValue),
                MCPMetaKeys.clientCapabilities: .object([:])
            ])
        ])
        let message = JsonRpcMessage.request(JsonRpcRequest(id: .number(3), method: "tools/call", params: params))
        let decoded = try JsonRpcCodec.decode(try JsonRpcCodec.encode(message))
        guard case .request(let request) = decoded else {
            Issue.record("Expected request")
            return
        }
        #expect(MCPRequestMeta.declaresModernProtocol(params: request.params))
        #expect(MCPRequestMeta.metaObject(in: request.params)?[MCPMetaKeys.protocolVersion]?.stringValue == MCPProtocolVersion.latest.rawValue)
    }

    @Test func testNotificationCarriesNoIdAfterARoundTrip() throws {
        let message = JsonRpcMessage.notification(
            JsonRpcNotification(method: "notifications/progress", params: .object(["progress": .double(0.25)]))
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        guard case .notification = decoded else {
            Issue.record("Expected notification")
            return
        }
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"id\""))
    }

    @Test func testDecodeRejectsAJsonFragment() {
        #expect(throws: (any Error).self) { try JsonRpcCodec.decode(Data("\"hello\"".utf8)) }
    }

    @Test func testDecodeRejectsAnEmptyBody() {
        if let error = #expect(throws: (any Error).self, performing: { try JsonRpcCodec.decode(Data()) }) {
            #expect(error as? JsonRpcDecodingError == .missingJsonRpcVersion)
        }
    }
}
