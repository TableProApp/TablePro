import XCTest
@testable import TableProR2SQLCore

final class R2SQLEnvelopeDecodingTests: XCTestCase {
    private func response(_ json: String, status: Int = 200) -> R2SQLHTTPResponse {
        R2SQLHTTPResponse(statusCode: status, body: Data(json.utf8))
    }

    func testSuccessEnvelopeDecodesSchemaAndRows() throws {
        let json = """
        {"result":{"request_id":"dqe-prod-test",
        "schema":[{"name":"id","type":"Int64"},{"name":"label","type":"Utf8"}],
        "rows":[{"id":1,"label":"a"},{"id":2,"label":"b"}],
        "metrics":{"r2_requests_count":3,"files_scanned":2,"bytes_scanned":1024}},
        "success":true,"errors":[],"messages":[]}
        """
        let result = try XCTUnwrap(try? R2SQLErrorClassifier.decode(response(json)).get())
        XCTAssertEqual(result.requestId, "dqe-prod-test")
        XCTAssertEqual(result.schema.map(\.name), ["id", "label"])
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.metrics?.bytesScanned, 1024)
    }

    func testEmptyResultSetIsSuccess() throws {
        let json = """
        {"result":{"schema":[],"rows":[],"metrics":{"r2_requests_count":0,"files_scanned":0,"bytes_scanned":0}},
        "success":true,"errors":[],"messages":[]}
        """
        let result = try XCTUnwrap(try? R2SQLErrorClassifier.decode(response(json)).get())
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertTrue(result.schema.isEmpty)
    }

    func testMissingMetricsStillDecodes() throws {
        let json = """
        {"result":{"schema":[{"name":"a","type":"Int64"}],"rows":[{"a":1}]},"success":true,"errors":[],"messages":[]}
        """
        let result = try XCTUnwrap(try? R2SQLErrorClassifier.decode(response(json)).get())
        XCTAssertNil(result.metrics)
        XCTAssertEqual(result.rows.count, 1)
    }

    func testSuccessTrueWithNullResultYieldsEmptyResult() throws {
        let json = #"{"result":null,"success":true,"errors":[],"messages":[]}"#
        let result = try XCTUnwrap(try? R2SQLErrorClassifier.decode(response(json)).get())
        XCTAssertTrue(result.rows.isEmpty)
    }

    func testErrorEnvelopeIsClassifiedAsFailure() {
        let json = #"{"result":null,"success":false,"errors":[{"code":80007,"message":"Unauthenticated."}]}"#
        guard case .failure(let error) = R2SQLErrorClassifier.decode(response(json, status: 401)) else {
            return XCTFail("Expected a failure")
        }
        guard case .authentication = error else {
            return XCTFail("Expected an authentication error, got \(error)")
        }
    }

    func testSuccessFalseUnderHTTP200IsStillFailure() {
        let json = #"{"result":null,"success":false,"errors":[{"code":40003,"message":"bad SQL"}]}"#
        guard case .failure(let error) = R2SQLErrorClassifier.decode(response(json, status: 200)) else {
            return XCTFail("Expected a failure")
        }
        XCTAssertEqual(error, .query(R2SQLAPIError(code: 40_003, message: "bad SQL")))
    }

    func testSuccessTrueUnderHTTP500IsStillSuccess() {
        let json = #"{"result":{"schema":[],"rows":[]},"success":true,"errors":[],"messages":[]}"#
        guard case .success = R2SQLErrorClassifier.decode(response(json, status: 500)) else {
            return XCTFail("success flag must decide the outcome, not the HTTP status")
        }
    }

    func testNonJSONBodyBecomesMalformedResponse() {
        let plain = R2SQLHTTPResponse(statusCode: 405, body: Data("Method not allowed.".utf8))
        guard case .failure(let error) = R2SQLErrorClassifier.decode(plain) else {
            return XCTFail("Expected a failure")
        }
        XCTAssertEqual(error, .malformedResponse(status: 405, body: "Method not allowed."))
    }

    func testEmptyBodyBecomesMalformedResponse() {
        let empty = R2SQLHTTPResponse(statusCode: 502, body: Data())
        guard case .failure(let error) = R2SQLErrorClassifier.decode(empty) else {
            return XCTFail("Expected a failure")
        }
        XCTAssertEqual(error, .malformedResponse(status: 502, body: ""))
    }

    func testMultipleErrorsAreAllSurfaced() {
        let json = """
        {"result":null,"success":false,"errors":[{"code":40003,"message":"first"},{"code":40004,"message":"second"}]}
        """
        guard case .failure(let error) = R2SQLErrorClassifier.decode(response(json)) else {
            return XCTFail("Expected a failure")
        }
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("first"))
        XCTAssertTrue(description.contains("second"))
    }

    func testInvalidAccountIdErrorMentionsAccountId() {
        let json = #"{"result":null,"success":false,"errors":[{"code":80016,"message":"Invalid account id"}]}"#
        guard case .failure(let error) = R2SQLErrorClassifier.decode(response(json, status: 400)) else {
            return XCTFail("Expected a failure")
        }
        XCTAssertTrue(error.errorDescription?.contains("Account ID") ?? false)
    }

    func testAuthenticationGuidanceNamesThePermissionGroups() {
        let error = R2SQLErrorClassifier.classify(
            errors: [R2SQLAPIError(code: 80_011, message: "Invalid token.")],
            statusCode: 403
        )
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("R2 SQL"))
        XCTAssertTrue(description.contains("R2 Data Catalog"))
        XCTAssertTrue(description.contains("R2 Storage"))
    }
}
