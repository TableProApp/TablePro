import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class JsonRpcMessageTests: XCTestCase {
    func testRequestRoundTrip() throws {
        let message = JsonRpcMessage.request(
            JsonRpcRequest(
                id: .number(1),
                method: "tools/list",
                params: .object(["cursor": .string("abc")])
            )
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        XCTAssertEqual(decoded, message)
    }

    func testRequestWithoutParamsRoundTrip() throws {
        let message = JsonRpcMessage.request(
            JsonRpcRequest(id: .string("req-1"), method: "ping", params: nil)
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        XCTAssertEqual(decoded, message)

        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"params\""))
    }

    func testNotificationRoundTrip() throws {
        let message = JsonRpcMessage.notification(
            JsonRpcNotification(method: "notifications/initialized", params: nil)
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        XCTAssertEqual(decoded, message)

        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"id\""))
        XCTAssertFalse(json.contains("\"params\""))
    }

    func testNotificationWithParamsRoundTrip() throws {
        let message = JsonRpcMessage.notification(
            JsonRpcNotification(
                method: "notifications/progress",
                params: .object(["progress": .int(50)])
            )
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        XCTAssertEqual(decoded, message)
    }

    func testSuccessResponseRoundTrip() throws {
        let message = JsonRpcMessage.successResponse(
            JsonRpcSuccessResponse(
                id: .number(7),
                result: .object(["tools": .array([])])
            )
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        XCTAssertEqual(decoded, message)
    }

    func testErrorResponseRoundTrip() throws {
        let message = JsonRpcMessage.errorResponse(
            JsonRpcErrorResponse(
                id: .number(8),
                error: JsonRpcError.methodNotFound(message: "not here")
            )
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        XCTAssertEqual(decoded, message)
    }

    func testErrorResponseWithNullIdEncodesAsJsonNull() throws {
        let message = JsonRpcMessage.errorResponse(
            JsonRpcErrorResponse(id: nil, error: JsonRpcError.parseError())
        )
        let data = try JsonRpcCodec.encode(message)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"id\":null"))
    }

    func testErrorResponseWithExplicitNullIdRoundTrips() throws {
        let message = JsonRpcMessage.errorResponse(
            JsonRpcErrorResponse(id: .null, error: JsonRpcError.serverError())
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        if case .errorResponse(let response) = decoded {
            XCTAssertEqual(response.id, .null)
        } else {
            XCTFail("Expected errorResponse")
        }
    }

    func testErrorResponseDataRoundTrip() throws {
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
        XCTAssertEqual(decoded, message)
    }

    func testErrorResponseWithoutDataOmitsField() throws {
        let message = JsonRpcMessage.errorResponse(
            JsonRpcErrorResponse(
                id: .number(10),
                error: JsonRpcError.methodNotFound()
            )
        )
        let data = try JsonRpcCodec.encode(message)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"data\""))
    }

    func testRejectsNon20JsonRpcVersion() {
        let raw = Data(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#.utf8)
        XCTAssertThrowsError(try JsonRpcCodec.decode(raw)) { error in
            guard case JsonRpcDecodingError.invalidJsonRpcVersion(let value) = error else {
                XCTFail("Expected invalidJsonRpcVersion, got \(error)")
                return
            }
            XCTAssertEqual(value, "1.0")
        }
    }

    func testRejectsMissingJsonRpcVersion() {
        let raw = Data(#"{"id":1,"method":"ping"}"#.utf8)
        XCTAssertThrowsError(try JsonRpcCodec.decode(raw)) { error in
            XCTAssertEqual(error as? JsonRpcDecodingError, .missingJsonRpcVersion)
        }
    }

    func testRejectsBatchArray() {
        let raw = Data(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#.utf8)
        XCTAssertThrowsError(try JsonRpcCodec.decode(raw)) { error in
            XCTAssertEqual(error as? JsonRpcDecodingError, .batchUnsupported)
        }
    }

    func testRejectsBatchArrayWithLeadingWhitespace() {
        let raw = Data("   \n[{\"jsonrpc\":\"2.0\"}]".utf8)
        XCTAssertThrowsError(try JsonRpcCodec.decode(raw)) { error in
            XCTAssertEqual(error as? JsonRpcDecodingError, .batchUnsupported)
        }
    }

    func testEncodeLineAppendsNewline() throws {
        let message = JsonRpcMessage.notification(
            JsonRpcNotification(method: "ping", params: nil)
        )
        let data = try JsonRpcCodec.encodeLine(message)
        XCTAssertEqual(data.last, 0x0A)
    }

    func testNullIdInRequestRoundTrips() throws {
        let message = JsonRpcMessage.request(
            JsonRpcRequest(id: .null, method: "test", params: nil)
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        XCTAssertEqual(decoded, message)
    }

    func testRejectsAmbiguousMessageWithMethodAndResult() {
        let raw = Data(#"{"jsonrpc":"2.0","id":1,"method":"foo","result":1}"#.utf8)
        XCTAssertThrowsError(try JsonRpcCodec.decode(raw)) { error in
            XCTAssertEqual(error as? JsonRpcDecodingError, .ambiguousMessage)
        }
    }

    func testRejectsResultAndError() {
        let raw = Data(#"{"jsonrpc":"2.0","id":1,"result":1,"error":{"code":-32000,"message":"x"}}"#.utf8)
        XCTAssertThrowsError(try JsonRpcCodec.decode(raw)) { error in
            XCTAssertEqual(error as? JsonRpcDecodingError, .ambiguousMessage)
        }
    }

    func testRejectsEmptyEnvelope() {
        let raw = Data(#"{"jsonrpc":"2.0","id":1}"#.utf8)
        XCTAssertThrowsError(try JsonRpcCodec.decode(raw)) { error in
            XCTAssertEqual(error as? JsonRpcDecodingError, .missingResultOrError)
        }
    }

    func testRejectsEnvelopeWithoutMethodOrIdEvenWithVersion() {
        let raw = Data(#"{"jsonrpc":"2.0"}"#.utf8)
        XCTAssertThrowsError(try JsonRpcCodec.decode(raw)) { error in
            XCTAssertEqual(error as? JsonRpcDecodingError, .missingMethod)
        }
    }

    func testSpecificationErrorCodesSurviveARoundTrip() throws {
        for code in [
            JsonRpcErrorCode.headerMismatch,
            JsonRpcErrorCode.missingRequiredClientCapability,
            JsonRpcErrorCode.unsupportedProtocolVersion
        ] {
            let message = JsonRpcMessage.errorResponse(
                JsonRpcErrorResponse(id: .number(1), error: JsonRpcError(code: code, message: "x"))
            )
            let decoded = try JsonRpcCodec.decode(try JsonRpcCodec.encode(message))
            XCTAssertEqual(decoded, message, "code \(code) must survive the wire")
        }
    }

    func testUnsupportedProtocolVersionDataRoundTrips() throws {
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
            XCTFail("Expected errorResponse")
            return
        }
        XCTAssertEqual(
            response.error.data?["supported"]?.arrayValue?.compactMap(\.stringValue),
            MCPProtocolVersion.supportedRawValues
        )
    }

    func testRequestMetaSurvivesTheWire() throws {
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
            XCTFail("Expected request")
            return
        }
        XCTAssertTrue(MCPRequestMeta.declaresModernProtocol(params: request.params))
        XCTAssertEqual(
            MCPRequestMeta.metaObject(in: request.params)?[MCPMetaKeys.protocolVersion]?.stringValue,
            MCPProtocolVersion.latest.rawValue
        )
    }

    func testNotificationCarriesNoIdAfterARoundTrip() throws {
        let message = JsonRpcMessage.notification(
            JsonRpcNotification(method: "notifications/progress", params: .object(["progress": .double(0.25)]))
        )
        let data = try JsonRpcCodec.encode(message)
        let decoded = try JsonRpcCodec.decode(data)
        guard case .notification = decoded else {
            XCTFail("Expected notification")
            return
        }
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"id\""))
    }

    func testDecodeRejectsAJsonFragment() {
        XCTAssertThrowsError(try JsonRpcCodec.decode(Data("\"hello\"".utf8)))
    }

    func testDecodeRejectsAnEmptyBody() {
        XCTAssertThrowsError(try JsonRpcCodec.decode(Data())) { error in
            XCTAssertEqual(error as? JsonRpcDecodingError, .missingJsonRpcVersion)
        }
    }
}
