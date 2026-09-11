import Foundation
import Testing
@testable import TableProR2SQLCore

@Suite("R2 SQL envelope decoding")
struct R2SQLEnvelopeDecodingTests {
    private func response(_ json: String, status: Int = 200) -> R2SQLHTTPResponse {
        R2SQLHTTPResponse(statusCode: status, body: Data(json.utf8))
    }

    @Test("The live envelope carries each column's type under descriptor.type.name")
    func descriptorEnvelope() throws {
        let json = """
        {"result":{"request_id":"dqe-prod-01",
        "schema":[{"name":"category","descriptor":{"type":{"name":"utf8"},"nullable":true}},
                  {"name":"cnt","descriptor":{"type":{"name":"int64"},"nullable":false}}],
        "rows":[{"category":"Electronics","cnt":12345}],
        "metrics":{"r2_requests_count":5,"files_scanned":29,"bytes_scanned":12345678,"cache_hits":0}},
        "success":true,"errors":[]}
        """
        let result = try R2SQLResponseDecoder.decode(response(json))

        #expect(result.schema == [
            R2SQLField(name: "category", typeName: "utf8", isNullable: true),
            R2SQLField(name: "cnt", typeName: "int64", isNullable: false)
        ])
        #expect(result.rows.first?["cnt"] == .number(12345))
    }

    @Test("A nested list of structs decodes its outer type and keeps the value tree")
    func nestedDescriptor() throws {
        let json = """
        {"success":true,"errors":[],"messages":[],"result":{"request_id":"dqe-prod-test",
        "schema":[{"name":"approx_top_k(value, Int64(3))","descriptor":{"type":{"name":"list","item":{"type":{"name":"struct",
        "fields":[{"type":{"name":"int64"},"nullable":true,"name":"value"},{"type":{"name":"uint64"},"nullable":false,"name":"count"}]},
        "nullable":true}},"nullable":true}}],
        "rows":[{"approx_top_k(value, Int64(3))":[{"value":0,"count":961},{"value":2,"count":null}]}],
        "metrics":{"r2_requests_count":6,"files_scanned":3,"bytes_scanned":62878}}}
        """
        let result = try R2SQLResponseDecoder.decode(response(json))

        #expect(result.schema.first?.typeName == "list")
        let mapped = R2SQLRowMapper.map(result)
        #expect(mapped.columnTypeNames == ["ARRAY"])
        #expect(mapped.rows == [[.text(#"[{"count":961,"value":0},{"count":null,"value":2}]"#)]])
    }

    @Test("A schema without a descriptor is a malformed response, not an empty success")
    func legacyShapeIsRejected() {
        let json = """
        {"result":{"schema":[{"name":"id","type":"Int64"}],"rows":[{"id":1}]},"success":true,"errors":[]}
        """
        #expect(throws: R2SQLError.self) { try R2SQLResponseDecoder.decode(response(json)) }
    }

    @Test("A body with no success flag is malformed")
    func missingSuccessIsMalformed() {
        #expect(throws: R2SQLError.malformedResponse(status: 200, detail: #"{"result":null}"#)) {
            try R2SQLResponseDecoder.decode(response(#"{"result":null}"#))
        }
    }

    @Test("A body that is not JSON is malformed and quotes the body")
    func nonJSONIsMalformed() {
        #expect(throws: R2SQLError.malformedResponse(status: 502, detail: "Bad gateway")) {
            try R2SQLResponseDecoder.decode(response("Bad gateway", status: 502))
        }
    }

    @Test("A success with a null result is an empty result")
    func nullResultIsEmpty() throws {
        let result = try R2SQLResponseDecoder.decode(response(#"{"result":null,"success":true,"errors":[]}"#))
        #expect(result.schema.isEmpty && result.rows.isEmpty)
    }

    @Test("A failure under 401 or 403 is an authentication error", arguments: [401, 403])
    func authenticationFailure(status: Int) {
        let json = #"{"result":null,"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}"#
        #expect(throws: R2SQLError.authentication(
            status: status,
            errors: [R2SQLAPIError(code: 10_000, message: "Authentication error")]
        )) {
            try R2SQLResponseDecoder.decode(response(json, status: status))
        }
    }

    @Test("Any other failure carries the server's errors, including under HTTP 200")
    func queryFailure() {
        let json = #"{"result":null,"success":false,"errors":[{"code":40003,"message":"syntax error at LIMIT"}]}"#
        let expected = R2SQLError.api(status: 200, errors: [R2SQLAPIError(code: 40_003, message: "syntax error at LIMIT")])

        #expect(throws: expected) { try R2SQLResponseDecoder.decode(response(json)) }
        #expect(expected.errorDescription == "syntax error at LIMIT")
    }
}
