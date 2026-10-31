import Foundation
import TableProPluginKit
import Testing

struct ClickHouseRedirectTests {
    @Test("A redirect to another server is refused, so the connection and its credentials stay where they point")
    func redirectElsewhereIsRefused() async throws {
        let elsewhere = ClickHouseStubServer()
        let target = "http://\(elsewhere.host):8123/"
        let server = ClickHouseStubServer { _ in
            ClickHouseStubReply(statusCode: 307, body: "", headers: ["Location": target])
        }
        let driver = server.unconnectedDriver()
        defer { driver.disconnect() }

        try? await driver.connect()
        await #expect(throws: (any Error).self) { try await driver.execute(query: "SELECT 1") }
        #expect(!server.requests.isEmpty)
        #expect(elsewhere.requests.isEmpty)
    }
}
