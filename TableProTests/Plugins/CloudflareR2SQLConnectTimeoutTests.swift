import Foundation
import TableProPluginKit
import TableProR2SQLCore
import Testing

private final class RecordingR2SQLTransport: R2SQLTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [R2SQLHTTPRequest] = []

    var requests: [R2SQLHTTPRequest] {
        lock.withLock { recordedRequests }
    }

    func send(_ request: R2SQLHTTPRequest) async throws -> R2SQLHTTPResponse {
        lock.withLock { recordedRequests.append(request) }
        let body = #"{"success":true,"errors":[],"result":{"schema":[],"rows":[]}}"#
        return R2SQLHTTPResponse(statusCode: 200, body: Data(body.utf8))
    }

    func cancelAll() {}
}

struct CloudflareR2SQLConnectTimeoutTests {
    @Test("Connect uses its deadline without changing later query timeouts", .timeLimit(.minutes(1)))
    func connectDeadlineIsRequestScoped() async throws {
        let transport = RecordingR2SQLTransport()
        let driver = CloudflareR2SQLPluginDriver(
            config: DriverConnectionConfig(
                host: "",
                port: 0,
                username: "",
                password: "token",
                database: "",
                additionalFields: [
                    "r2AccountId": "account",
                    "r2Bucket": "bucket",
                    "connectTimeoutMilliseconds": "2500"
                ]
            ),
            transport: transport
        )

        try await driver.connect()

        let connectRequest = try #require(transport.requests.first)
        #expect(connectRequest.timeoutInterval > 0)
        #expect(connectRequest.timeoutInterval <= 2.5)

        try await driver.applyQueryTimeout(300)
        _ = try await driver.run(sql: "SELECT 1")

        #expect(transport.requests.count == 2)
        let queryRequest = try #require(transport.requests.last)
        #expect(queryRequest.timeoutInterval == HttpQueryTimeout(serverTimeoutSeconds: 300).requestTimeoutInterval)
    }
}
