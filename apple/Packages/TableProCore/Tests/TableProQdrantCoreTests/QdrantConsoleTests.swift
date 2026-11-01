import Foundation
@testable import TableProQdrantCore
import Testing

struct QdrantConsoleTests {
    @Test("The console reads a request line with its body below, beside, or starting beside and going on below")
    func parser() {
        let below = QdrantConsoleParser.parse("POST /collections/docs/points/query\n{\"limit\": 3}")
        #expect(below == QdrantConsoleRequest(method: "POST", path: "/collections/docs/points/query", body: "{\"limit\": 3}"))
        let inline = QdrantConsoleParser.parse("post /collections/docs/points/count {\"exact\": true}")
        #expect(inline?.method == "POST")
        #expect(inline?.body == "{\"exact\": true}")
        let split = QdrantConsoleParser.parse("POST /collections/docs/points/query {\n  \"query\": [0.1, 0.2], \"limit\": 5 }")
        #expect(split?.body == "{\n\"query\": [0.1, 0.2], \"limit\": 5 }")
        let crlf = QdrantConsoleParser.parse("GET /collections\r\n")
        #expect(crlf == QdrantConsoleRequest(method: "GET", path: "/collections", body: nil))
        #expect(QdrantConsoleParser.parse("DELETE\t/collections/docs")?.method == "DELETE")
        #expect(QdrantConsoleParser.parse("SELECT 1") == nil)
        #expect(QdrantConsoleParser.parse("GET collections") == nil)
    }

    @Test("Reads, writes and removals are told apart by verb and route")
    func requestKinds() {
        func tier(_ method: String, _ path: String) -> QdrantRequestKind.Tier {
            QdrantRequestKind.of(method: method, path: path).tier
        }
        #expect(tier("POST", "/collections/docs/points/query") == .read)
        #expect(tier("POST", "/collections/docs/points") == .read)
        #expect(tier("POST", "/collections/docs/facet") == .read)
        #expect(tier("POST", "/collections/docs/points/facet") == .write)
        #expect(tier("GET", "/collections") == .read)
        #expect(tier("PUT", "/collections/docs/points?wait=true") == .write)
        #expect(tier("POST", "/collections/docs/points/payload") == .write)
        #expect(tier("POST", "/collections/docs/points/delete?wait=true") == .remove)
        #expect(tier("POST", "/collections/docs/points/payload/clear") == .remove)
        #expect(tier("POST", "/collections/docs/points/batch") == .remove)
        #expect(tier("DELETE", "/collections/docs") == .remove)
    }

    @Test("A snapshot touches the server's disk, and a dot segment is never read as another route")
    func serverFilesAndDotSegments() {
        #expect(QdrantRequestKind.of(method: "POST", path: "/collections/docs/snapshots").touchesServerFiles)
        #expect(!QdrantRequestKind.of(method: "GET", path: "/collections").touchesServerFiles)
        let dotted = QdrantRequestKind.of(method: "POST", path: "/collections/docs/points/query/../delete")
        #expect(dotted == QdrantRequestKind(tier: .write, touchesServerFiles: true))
        #expect(QdrantPathEncoding.segments(of: "/collections/%2e%2e/x") == nil)
    }

    @Test("A request path keeps its query string and never leaves the node")
    func pathResolution() throws {
        let base = try #require(URL(string: "http://localhost:6333"))
        let url = QdrantPathEncoding.resolve("/collections/docs/points?wait=true", against: base)
        #expect(url?.absoluteString == "http://localhost:6333/collections/docs/points?wait=true")
        #expect(QdrantPathEncoding.resolve("//evil.example/x", against: base) == nil)
        #expect(QdrantPathEncoding.resolve("/collections/docs/points/query/../delete", against: base) == nil)
    }

    @Test("Browse requests round-trip through their tag with every sort column")
    func browseRoundTrip() throws {
        let request = QdrantBrowseRequest(
            collection: "docs",
            offset: 200,
            limit: 100,
            sorts: [QdrantSortSpec(column: "pop", ascending: false), QdrantSortSpec(column: "city", ascending: true)],
            filters: [QdrantFilterSpec(column: "count", op: "BETWEEN", value: "1,5", secondValue: "5")],
            logicMode: "OR"
        )
        #expect(QdrantBrowseQuery.parse(QdrantBrowseQuery.encode(request)) == request)
    }

    @Test("A sort Qdrant cannot honor is refused rather than ignored")
    func sortPlans() throws {
        #expect(try QdrantSortPlan.resolve([]) == .byID)
        #expect(try QdrantSortPlan.resolve([QdrantSortSpec(column: "id", ascending: true)]) == .byID)
        #expect(try QdrantSortPlan.resolve([QdrantSortSpec(column: "pop", ascending: false)])
            == .byPayload(column: "pop", key: "\"pop\"", ascending: false))
        #expect(throws: QdrantError.self) { try QdrantSortPlan.resolve([QdrantSortSpec(column: "id", ascending: false)]) }
        #expect(throws: QdrantError.self) { try QdrantSortPlan.resolve([QdrantSortSpec(column: "vector.image", ascending: true)]) }
        #expect(throws: QdrantError.self) {
            try QdrantSortPlan.resolve([QdrantSortSpec(column: "pop", ascending: true), QdrantSortSpec(column: "city", ascending: true)])
        }
    }

    @Test("Drop, truncate and export are request lines or tags the driver reads back")
    func operations() {
        #expect(QdrantOperations.deleteCollection(named: "my docs", objectType: "TABLE") == "DELETE /collections/my%20docs")
        #expect(QdrantOperations.deleteCollection(named: "docs", objectType: "VIEW") == nil)
        #expect(QdrantOperations.deleteAllPoints(collection: "docs")
            == "POST /collections/docs/points/delete?wait=true\n{\"filter\":{}}")
        #expect(QdrantOperations.decodeExport(QdrantOperations.encodeExport(collection: "docs")) == "docs")
    }
}
