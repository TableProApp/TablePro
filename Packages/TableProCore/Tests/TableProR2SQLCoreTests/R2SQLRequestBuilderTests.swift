import Foundation
import Testing
@testable import TableProR2SQLCore

@Suite("R2 SQL request")
struct R2SQLRequestBuilderTests {
    private let config = R2SQLConnectionConfig(accountId: " acc123 ", bucket: "my-bucket", token: " tok \n")

    @Test("The request posts the query alone to the account's bucket endpoint with a bearer token")
    func request() throws {
        let request = try R2SQLRequestBuilder.queryRequest(config: config, sql: "SELECT 1", timeoutInterval: 330)
        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: String])

        #expect(request.url.absoluteString
            == "https://api.sql.cloudflarestorage.com/api/v1/accounts/acc123/r2-sql/query/my-bucket")
        #expect(body == ["query": "SELECT 1"])
        #expect(request.headers["Authorization"] == "Bearer tok")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.timeoutInterval == 330)
    }

    @Test("A missing account, bucket or token fails before any request", arguments: [
        R2SQLConnectionConfig(accountId: "", bucket: "b", token: "t"),
        R2SQLConnectionConfig(accountId: "a", bucket: " ", token: "t"),
        R2SQLConnectionConfig(accountId: "a", bucket: "b", token: "")
    ])
    func validation(config: R2SQLConnectionConfig) {
        #expect(throws: R2SQLError.self) {
            try R2SQLRequestBuilder.queryRequest(config: config, sql: "SELECT 1", timeoutInterval: 60)
        }
    }
}
