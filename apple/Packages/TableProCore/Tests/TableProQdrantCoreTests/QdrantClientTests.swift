import Foundation
@testable import TableProQdrantCore
import Testing

struct QdrantClientTests {
    @Test("Paging forward reuses the cursor the previous page returned")
    func pagingForward() async throws {
        let transport = scrollingTransport(count: 25)
        let client = makeClient(transport: transport)
        let cache = QdrantCursorCache()

        let first = try await client.scrollPage(collection: "docs", filter: nil, offset: 0, limit: 10, cache: cache)
        let second = try await client.scrollPage(collection: "docs", filter: nil, offset: 10, limit: 10, cache: cache)

        #expect(first.compactMap(\.idText) == (1...10).map(String.init))
        #expect(second.compactMap(\.idText) == (11...20).map(String.init))
        #expect(transport.recorded.count == 2)
        #expect(bodyObject(transport.recorded[1])["offset"] as? Int == 11)
    }

    @Test("A jump with no cursor walks ids only, then reads the page")
    func jump() async throws {
        let transport = scrollingTransport(count: 25)
        let client = makeClient(transport: transport)

        let page = try await client.scrollPage(collection: "docs", filter: nil, offset: 20, limit: 10, cache: QdrantCursorCache())

        #expect(page.compactMap(\.idText) == (21...25).map(String.init))
        let walk = bodyObject(transport.recorded[0])
        #expect(walk["limit"] as? Int == 20)
        #expect(walk["with_payload"] as? Bool == false)
        #expect(walk["with_vector"] as? Bool == false)
    }

    @Test("An offset past the end answers an empty page")
    func pastEnd() async throws {
        let client = makeClient(transport: scrollingTransport(count: 5))
        let page = try await client.scrollPage(collection: "docs", filter: nil, offset: 10, limit: 10, cache: QdrantCursorCache())
        #expect(page.isEmpty)
    }

    @Test("Export walks every page until the cursor runs out")
    func export() async throws {
        let client = makeClient(transport: scrollingTransport(count: 7))
        var ids: [String] = []
        for try await page in client.pointPages(collection: "docs", pageSize: 3) {
            ids += page.compactMap(\.idText)
        }
        #expect(ids == (1...7).map(String.init))
    }

    @Test("The API key travels in the api-key header and errors carry Qdrant's reason")
    func headersAndErrors() async throws {
        let transport = RecordingTransport { _ in
            jsonResponse(["status": ["error": "Not found: Collection `nope` doesn't exist!"]], status: 404)
        }
        let client = makeClient(apiKey: "secret", transport: transport)
        await #expect(throws: QdrantError.api(status: 404, message: "Not found: Collection `nope` doesn't exist!")) {
            _ = try await client.collection(named: "nope")
        }
        #expect(transport.recorded.first?.headers["api-key"] == "secret")
    }

    @Test("A rejected key is an authentication error")
    func authentication() {
        let error = QdrantError.from(status: 401, body: Data("Invalid api-key".utf8))
        #expect(error == .authentication("Invalid api-key"))
    }

    @Test("A request path keeps its query string")
    func pathResolution() throws {
        let base = try #require(URL(string: "http://localhost:6333"))
        let url = QdrantPathEncoding.resolve("/collections/docs/points?wait=true", against: base)
        #expect(url?.absoluteString == "http://localhost:6333/collections/docs/points?wait=true")
        #expect(QdrantPathEncoding.resolve("//evil.example/x", against: base) == nil)
    }
}
