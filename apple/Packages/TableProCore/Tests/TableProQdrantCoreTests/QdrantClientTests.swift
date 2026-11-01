import Foundation
@testable import TableProQdrantCore
import Testing

struct QdrantClientTests {
    @Test("On Qdrant 1.10 or later a page is one query with the offset applied on the server")
    func pageByServerOffset() async throws {
        let transport = RecordingTransport { request in
            switch request.url.path {
            case "/": return jsonResponse(["version": "1.20.0"])
            case "/collections": return jsonResponse(["result": ["collections": [Any]()]])
            default: return jsonResponse(["result": ["points": [["id": 101, "payload": [String: Any]()]]]])
            }
        }
        let client = makeClient(transport: transport)
        try await client.connect(requestTimeout: { 5 })
        let filter: [String: Any] = ["must": [["has_id": [101]]]]
        let page = try await client.pointPage(collection: "docs", filter: filter, offset: 100, limit: 10)
        #expect(page.compactMap(\.idText) == ["101"])
        let request = try #require(transport.recorded.last)
        #expect(request.url.path == "/collections/docs/points/query")
        #expect(canonical(bodyObject(request)) == #"{"filter":{"must":[{"has_id":[101]}]},"limit":10,"offset":100,"with_payload":true,"with_vector":true}"#)
    }

    @Test("An older node walks ids from the start every time, so no cached position can go stale")
    func olderNodeWalksIDs() async throws {
        let transport = scrollingTransport(count: 25_000)
        let client = makeClient(transport: transport)
        let page = try await client.pointPage(collection: "docs", filter: nil, offset: 20_000, limit: 10)
        #expect(page.compactMap(\.idText) == (20_001...20_010).map(String.init))
        let walks = transport.scrolls.dropLast().map(bodyObject)
        #expect(walks.map { $0["limit"] as? Int } == [10_000, 10_000])
        #expect(walks.allSatisfy { $0["with_payload"] as? Bool == false && $0["with_vector"] as? Bool == false })
        _ = try await client.pointPage(collection: "docs", filter: nil, offset: 20_000, limit: 10)
        #expect(transport.scrolls.count == 6)
    }

    @Test("An offset past the end answers an empty page")
    func pastEnd() async throws {
        let client = makeClient(transport: scrollingTransport(count: 5))
        let page = try await client.pointPage(collection: "docs", filter: nil, offset: 10, limit: 10)
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
        #expect(QdrantError.from(status: 401, body: Data("Invalid api-key".utf8)) == .authentication("Invalid api-key"))
    }

    @Test("Collection info is one GET, without the payload sample the columns need")
    func infoOnly() async throws {
        let transport = RecordingTransport { _ in
            jsonResponse(["result": ["points_count": 12, "config": ["params": ["vectors": ["size": 2]]]], "status": "ok"])
        }
        let collection = try await makeClient(transport: transport).collectionInfo(named: "docs")
        #expect(collection.pointsCount == 12)
        #expect(transport.recorded.map(\.method) == ["GET"])
    }
}

// Ordered points 1...6 by `price`, then 7...9 without a price.
struct QdrantSortedPagerTests {
    private func transport(listed: Int = 0) -> RecordingTransport {
        RecordingTransport { request in
            let body = bodyObject(request)
            let text = canonical(body)
            switch request.url.path {
            case "/collections/docs/points/count":
                if text.contains("values_count") { return jsonResponse(["result": ["count": listed]]) }
                return jsonResponse(["result": ["count": 6]])
            case "/collections/docs/points/query":
                let offset = body["offset"] as? Int ?? 0
                let limit = body["limit"] as? Int ?? 10
                let ids = Array((1...6).dropFirst(offset).prefix(limit))
                return jsonResponse(["result": ["points": ids.map { ["id": $0, "payload": ["price": $0]] }]])
            case "/collections/docs/points/scroll":
                let limit = body["limit"] as? Int ?? 10
                let start = body["offset"] as? Int ?? 7
                let ids = Array(start..<min(start + limit, 10))
                return scrollResponse(ids, next: start + limit <= 9 ? start + limit : nil)
            default:
                return jsonResponse(["status": ["error": "unexpected \(request.url.path)"]], status: 404)
            }
        }
    }

    private func page(_ client: QdrantClient, offset: Int, limit: Int, cache: QdrantPagingCache) async throws -> [String] {
        try await client.sortedPage(
            collection: "docs", filter: nil, column: "price", key: "\"price\"", ascending: true,
            offset: offset, limit: limit, cache: cache
        ).compactMap(\.idText)
    }

    @Test("Points with a value come first in order, then the points without one, and every point is reachable")
    func orderedThenRemainder() async throws {
        let transport = transport()
        let client = makeClient(transport: transport)
        let cache = QdrantPagingCache()

        #expect(try await page(client, offset: 0, limit: 4, cache: cache) == ["1", "2", "3", "4"])
        #expect(try await page(client, offset: 4, limit: 4, cache: cache) == ["5", "6", "7", "8"])
        #expect(try await page(client, offset: 8, limit: 4, cache: cache) == ["9"])

        let query = try #require(transport.recorded.first { $0.url.path.hasSuffix("/query") })
        #expect(canonical(bodyObject(query)["query"] ?? [:]) == #"{"order_by":{"direction":"asc","key":"\"price\""}}"#)
        let remainder = try #require(transport.recorded.first { $0.url.path.hasSuffix("/scroll") })
        #expect(canonical(bodyObject(remainder)["filter"] ?? [:])
            == #"{"must":[{"must_not":[{"key":"\"price\"","range":{}}]}]}"#)
        #expect(transport.recorded.filter { canonical(bodyObject($0)).contains("values_count") }.count == 1)
    }

    @Test("A field Qdrant cannot order by is refused, never shown in id order as if sorted")
    func unorderableFieldRefused() async throws {
        let transport = RecordingTransport { request in
            guard request.url.path.hasSuffix("/query") else { return jsonResponse(["result": ["count": 0]]) }
            return jsonResponse(["status": ["error": "Wrong input: No range index for `order_by` key: `city`."]], status: 400)
        }
        await #expect(throws: QdrantError.api(status: 400, message: "Wrong input: No range index for `order_by` key: `city`.")) {
            _ = try await makeClient(transport: transport).sortedPage(
                collection: "docs", filter: nil, column: "city", key: "\"city\"", ascending: true,
                offset: 0, limit: 4, cache: QdrantPagingCache()
            )
        }
    }

    @Test("A field holding a list in some point is refused, since Qdrant would show that point once per value")
    func listedValuesRefused() async throws {
        let client = makeClient(transport: transport(listed: 2))
        await #expect(throws: QdrantError.self) {
            _ = try await page(client, offset: 0, limit: 4, cache: QdrantPagingCache())
        }
    }
}
