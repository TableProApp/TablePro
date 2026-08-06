import XCTest
@testable import TableProR2SQLCore

final class R2SQLRequestBuilderTests: XCTestCase {
    private let config = R2SQLConnectionConfig(
        accountId: "abc123",
        bucket: "my-bucket",
        token: "secret-token"
    )

    func testWarehouseIsAccountIdUnderscoreBucket() {
        XCTAssertEqual(config.warehouse, "abc123_my-bucket")
    }

    func testWarehouseRoundTripsThroughSplit() {
        let parts = R2SQLWarehouse.split(config.warehouse)
        XCTAssertEqual(parts?.accountId, "abc123")
        XCTAssertEqual(parts?.bucket, "my-bucket")
    }

    func testWarehouseSplitUsesFirstUnderscoreOnly() {
        let parts = R2SQLWarehouse.split("acct_my_bucket_with_underscores")
        XCTAssertEqual(parts?.accountId, "acct")
        XCTAssertEqual(parts?.bucket, "my_bucket_with_underscores")
    }

    func testWarehouseSplitRejectsMissingSeparator() {
        XCTAssertNil(R2SQLWarehouse.split("nounderscore"))
    }

    func testQueryURLMatchesDocumentedEndpoint() {
        XCTAssertEqual(
            config.queryURL?.absoluteString,
            "https://api.sql.cloudflarestorage.com/api/v1/accounts/abc123/r2-sql/query/my-bucket"
        )
    }

    func testRequestCarriesBearerTokenAndJSONContentType() throws {
        let request = try R2SQLRequestBuilder.queryRequest(config: config, sql: "SELECT 1 FROM t")
        XCTAssertEqual(request.headers["Authorization"], "Bearer secret-token")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
    }

    func testRequestBodyCarriesBothWarehouseAndQuery() throws {
        let request = try R2SQLRequestBuilder.queryRequest(config: config, sql: "SELECT * FROM ns.t LIMIT 10")
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.body) as? [String: String]
        )
        XCTAssertEqual(decoded["warehouse"], "abc123_my-bucket")
        XCTAssertEqual(decoded["query"], "SELECT * FROM ns.t LIMIT 10")
        XCTAssertEqual(decoded.count, 2)
    }

    func testRequestUsesConfiguredTimeout() throws {
        let timed = R2SQLConnectionConfig(accountId: "a", bucket: "b", token: "t", timeoutSeconds: 15)
        let request = try R2SQLRequestBuilder.queryRequest(config: timed, sql: "SELECT 1 FROM t")
        XCTAssertEqual(request.timeoutSeconds, 15)
    }

    func testMissingAccountIdIsRejected() {
        let invalid = R2SQLConnectionConfig(accountId: "", bucket: "b", token: "t")
        XCTAssertEqual(invalid.validate(), .configuration(R2SQLErrorText.missingAccountId))
        XCTAssertThrowsError(try R2SQLRequestBuilder.queryRequest(config: invalid, sql: "SELECT 1 FROM t"))
    }

    func testMissingBucketIsRejected() {
        let invalid = R2SQLConnectionConfig(accountId: "a", bucket: "", token: "t")
        XCTAssertEqual(invalid.validate(), .configuration(R2SQLErrorText.missingBucket))
    }

    func testMissingTokenIsRejected() {
        let invalid = R2SQLConnectionConfig(accountId: "a", bucket: "b", token: "")
        XCTAssertEqual(invalid.validate(), .configuration(R2SQLErrorText.missingToken))
    }

    func testValidConfigurationPassesValidation() {
        XCTAssertNil(config.validate())
    }

    func testWhitespaceIsTrimmedFromIdentifiers() {
        let padded = R2SQLConnectionConfig(accountId: "  abc123 ", bucket: " my-bucket\n", token: "t")
        XCTAssertEqual(padded.warehouse, "abc123_my-bucket")
    }
}
