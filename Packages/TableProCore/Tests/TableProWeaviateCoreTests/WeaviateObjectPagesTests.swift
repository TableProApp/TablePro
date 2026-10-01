import Foundation
@testable import TableProWeaviateCore
import Testing

@Suite("Weaviate object pages")
struct WeaviateObjectPagesTests {
    @Test("Reading a collection past the query maximum yields every object once, in order")
    func readsPastQueryMaximum() async throws {
        let transport = CursorPagingWeaviateTransport(objectCount: 12_000)
        let client = testClient(transport: transport)

        var uuids: [String] = []
        for try await page in client.objectPages(collection: "Article", pageSize: 500) {
            uuids += page.map(\.uuid)
        }

        #expect(uuids.count == 12_000)
        #expect(uuids == transport.uuids)
    }

    @Test("The first page is a plain listing, so an object at the nil uuid is not skipped")
    func firstPageKeepsTheNilUUID() async throws {
        let transport = CursorPagingWeaviateTransport(objectCount: 1_200)
        let client = testClient(transport: transport)

        var uuids: [String] = []
        for try await page in client.objectPages(collection: "Article", pageSize: 500) {
            uuids += page.map(\.uuid)
        }

        #expect(uuids.first == CursorPagingWeaviateTransport.nilUUID)
        #expect(uuids == transport.uuids)
    }

    @Test("Each later page starts after the last uuid of the page before it")
    func pagesByCursor() async throws {
        let transport = CursorPagingWeaviateTransport(objectCount: 1_200)
        let client = testClient(transport: transport)

        var pages: [[WeaviateObject]] = []
        for try await page in client.objectPages(collection: "Article", pageSize: 500) {
            pages.append(page)
        }

        #expect(pages.map(\.count) == [500, 500, 200])
        #expect(transport.queries.map { $0["after"] } == [nil, pages[0].last?.uuid, pages[1].last?.uuid])
        #expect(transport.queries.allSatisfy { $0["offset"] == nil })
        #expect(transport.queries.allSatisfy { $0["class"] == "Article" && $0["include"] == "vector" })
    }

    @Test("A collection that fills its last page exactly ends on the empty page after it")
    func endsOnEmptyPage() async throws {
        let transport = CursorPagingWeaviateTransport(objectCount: 1_000)
        let client = testClient(transport: transport)

        var counts: [Int] = []
        for try await page in client.objectPages(collection: "Article", pageSize: 500) {
            counts.append(page.count)
        }

        #expect(counts == [500, 500])
        #expect(transport.queries.count == 3)
    }

    @Test("A server that ignores the cursor fails the read instead of repeating the first page")
    func refusesACursorThatDoesNotMove() async throws {
        let transport = CursorPagingWeaviateTransport(objectCount: 1_200, honorsCursor: false)
        let client = testClient(transport: transport)

        let expected = WeaviateError.malformedResponse(
            "Weaviate returned the same page of Article twice. Reading a whole collection needs Weaviate 1.18 or later."
        )
        await #expect(throws: expected) {
            for try await _ in client.objectPages(collection: "Article", pageSize: 500) {}
        }
        #expect(transport.queries.count == 2)
    }

    @Test("A full page whose last object has no id cannot be paged past, so the read fails")
    func refusesAPageWithoutACursor() async throws {
        let transport = FakeWeaviateTransport()
        transport.respond(
            method: "GET",
            path: "/v1/objects",
            status: 200,
            json: ["objects": [["class": "Article", "properties": ["title": "Hello"]]]]
        )
        let client = testClient(transport: transport)

        let expected = WeaviateError.malformedResponse(
            "Weaviate returned an object of Article without an id, so the rest of the collection cannot be read."
        )
        await #expect(throws: expected) {
            for try await _ in client.objectPages(collection: "Article", pageSize: 1) {}
        }
        #expect(transport.requests.count == 1)
    }

    @Test("Leaving out the vector leaves out the include parameter")
    func omitsVectorWhenAsked() async throws {
        let transport = CursorPagingWeaviateTransport(objectCount: 10)
        let client = testClient(transport: transport)

        for try await _ in client.objectPages(collection: "Article", pageSize: 500, includeVector: false) {}

        #expect(transport.queries.map { $0["include"] } == [nil])
    }
}

final class CursorPagingWeaviateTransport: WeaviateTransport, @unchecked Sendable {
    static let nilUUID = "00000000-0000-0000-0000-000000000000"

    let uuids: [String]
    private let queryMaximumResults: Int
    private let honorsCursor: Bool
    private(set) var queries: [[String: String]] = []

    init(objectCount: Int, queryMaximumResults: Int = 10_000, honorsCursor: Bool = true) {
        uuids = (0..<objectCount).map { index in
            index == 0 ? Self.nilUUID : String(format: "00000000-0000-4000-8000-%012d", index)
        }
        self.queryMaximumResults = queryMaximumResults
        self.honorsCursor = honorsCursor
    }

    func send(_ request: WeaviateHTTPRequest) async throws -> WeaviateHTTPResponse {
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        queries.append(query)

        let limit = Int(query["limit"] ?? "") ?? 25
        let offset = Int(query["offset"] ?? "") ?? 0
        if honorsCursor, let after = query["after"] {
            guard offset == 0 else {
                return refusal("offset cannot be set with after and limit parameters")
            }
            let start = uuids.firstIndex { $0 > after } ?? uuids.count
            return page(start: start, limit: limit)
        }
        guard offset + limit <= queryMaximumResults else {
            return refusal("query maximum results exceeded")
        }
        return page(start: offset, limit: limit)
    }

    func cancelAll() {}

    private func page(start: Int, limit: Int) -> WeaviateHTTPResponse {
        let lower = min(max(start, 0), uuids.count)
        let upper = min(lower + max(limit, 0), uuids.count)
        let objects: [[String: Any]] = uuids[lower..<upper].map { uuid in
            ["id": uuid, "class": "Article", "properties": ["title": uuid], "vector": [0.1, 0.2]]
        }
        let body = (try? JSONSerialization.data(withJSONObject: ["objects": objects])) ?? Data()
        return WeaviateHTTPResponse(statusCode: 200, body: body)
    }

    private func refusal(_ message: String) -> WeaviateHTTPResponse {
        let json: [String: Any] = ["error": [["message": "msg:offset or limit code:400 err:\(message)"]]]
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return WeaviateHTTPResponse(statusCode: 422, body: body)
    }
}
