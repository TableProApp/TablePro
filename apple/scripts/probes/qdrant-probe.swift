import Foundation
import TableProQdrantCore

// Exercises TableProQdrantCore against a live node: the facts the driver relies on, measured.
// Run through check-qdrant.sh, which builds it against this checkout's TableProCore.

var failures = 0
@MainActor func check(_ ok: Bool, _ label: String) {
    print(ok ? "PASS" : "FAIL", label)
    if !ok { failures += 1 }
}

let env = ProcessInfo.processInfo.environment
let settings = QdrantConnectionSettings(
    host: env["QDRANT_HOST"] ?? "127.0.0.1",
    port: Int(env["QDRANT_PORT"] ?? "") ?? 6333,
    usesTLS: false,
    apiKey: env["QDRANT_API_KEY"] ?? "",
    skipTLSVerify: false
)
let client = QdrantClient(settings: settings, transport: URLSessionQdrantTransport(resourceTimeout: 30), timeout: { 10 })
try await client.connect(requestTimeout: { 10 })
print("version", client.serverVersion ?? "nil")

_ = try? await client.execute(QdrantConsoleRequest(method: "DELETE", path: "/collections/tablepro_probe", body: nil))
_ = try await client.execute(QdrantConsoleRequest(method: "PUT", path: "/collections/tablepro_probe", body: #"{"vectors":{"size":2,"distance":"Dot"}}"#))
var points: [[String: Any]] = []
for i in 1...250 { points.append(["id": i, "vector": [Double(i), 1], "payload": ["n": i, "city": i % 2 == 0 ? "even" : "odd", "body": "hello world \(i)"]]) }
_ = try await client.execute(QdrantConsoleRequest(method: "PUT", path: "/collections/tablepro_probe/points?wait=true", body: try QdrantJSON.text(["points": points])))
_ = try await client.execute(QdrantConsoleRequest(method: "PUT", path: "/collections/tablepro_probe/index?wait=true", body: #"{"field_name":"n","field_schema":"integer"}"#))
_ = try await client.execute(QdrantConsoleRequest(method: "PUT", path: "/collections/tablepro_probe/index?wait=true", body: #"{"field_name":"body","field_schema":"text"}"#))

check(try await client.collectionNames().contains("tablepro_probe"), "lists collection")
let collection = try await client.collection(named: "tablepro_probe")
print("columns", QdrantSchema.columns(for: collection).map { "\($0.name):\($0.type)" })
check(collection.pointsCount == 250, "points_count")

let cache = QdrantCursorCache()
let p0 = try await client.scrollPage(collection: "tablepro_probe", filter: nil, offset: 0, limit: 100, cache: cache)
let p1 = try await client.scrollPage(collection: "tablepro_probe", filter: nil, offset: 100, limit: 100, cache: cache)
let p2 = try await client.scrollPage(collection: "tablepro_probe", filter: nil, offset: 200, limit: 100, cache: cache)
check(p0.first?.idText == "1" && p1.first?.idText == "101" && p2.count == 50 && p2.last?.idText == "250", "paging forward")
let jump = try await client.scrollPage(collection: "tablepro_probe", filter: nil, offset: 170, limit: 10, cache: QdrantCursorCache())
check(jump.map { $0.idText ?? "" } == (171...180).map(String.init), "jump walks to offset")
check(try await client.scrollPage(collection: "tablepro_probe", filter: nil, offset: 400, limit: 10, cache: cache).isEmpty, "past end")

func filtered(_ specs: [QdrantFilterSpec], _ mode: String = "AND") async throws -> Int {
    let f = try QdrantFilterBuilder.filter(specs, logicMode: mode, collection: collection)
    return try await client.count(collection: "tablepro_probe", filter: f)
}
check(try await filtered([QdrantFilterSpec(column: "city", op: "=", value: "even")]) == 125, "match keyword")
check(try await filtered([QdrantFilterSpec(column: "n", op: "BETWEEN", value: "10,19", secondValue: "19")]) == 10, "between")
check(try await filtered([QdrantFilterSpec(column: "n", op: ">", value: "240"), QdrantFilterSpec(column: "city", op: "!=", value: "even")]) == 5, "and with not")
check(try await filtered([QdrantFilterSpec(column: "n", op: "<", value: "3"), QdrantFilterSpec(column: "n", op: ">", value: "248")], "OR") == 4, "or")
check(try await filtered([QdrantFilterSpec(column: "body", op: "CONTAINS", value: "hello")]) == 250, "full text")
check(try await filtered([QdrantFilterSpec(column: "id", op: "IN", value: "1,2,3")]) == 3, "has_id")
check(try await filtered([QdrantFilterSpec(column: "n", op: "IN", value: "1,2,300")]) == 2, "match any")
check(try await filtered([QdrantFilterSpec(column: "missing", op: "IS NULL", value: "")]) == 0, "is_null")
check(try await filtered([QdrantFilterSpec(column: "missing", op: "IS EMPTY", value: "")]) == 250, "is_empty")

let sortReq = QdrantBrowseRequest(collection: "tablepro_probe", offset: 5, limit: 3, sort: QdrantSortSpec(column: "n", ascending: false), filters: [], logicMode: "AND")
let sorted = try await client.query(collection: "tablepro_probe", body: QdrantBrowseQuery.queryBody(for: sortReq, filter: nil, sort: sortReq.sort!))
check(sorted.map { $0.idText ?? "" } == ["245", "244", "243"], "order_by with offset")

let batch = QdrantStatementGenerator.generate(collection: collection, changes: [
    QdrantTrackedChange(kind: .update, id: "1", cellChanges: [QdrantCellChange(column: "city", newText: "edited"), QdrantCellChange(column: "n", newText: "1000")]),
    QdrantTrackedChange(kind: .delete, id: "2"),
    QdrantTrackedChange(kind: .insert, id: "999", values: ["city": "new"]),
    QdrantTrackedChange(kind: .insert, id: "3", values: ["city": "clobber"])
])
for request in batch.requests {
    let text = QdrantWriteCodec.encode(request)
    _ = try await client.execute(QdrantConsoleParser.parse(text)!)
}
let after = try await client.query(collection: "tablepro_probe", body: ["query": NSNull(), "filter": ["must": [["has_id": [1, 2, 3, 999]]]], "with_payload": true, "limit": 10] as [String: Any])
let byID = Dictionary(uniqueKeysWithValues: after.map { ($0.idText ?? "", $0) })
check(byID["1"]?.cell(for: "city") == "edited" && byID["1"]?.cell(for: "n") == "1000", "set payload typed")
check(byID["2"] == nil, "delete")
check(byID["999"]?.cell(for: "city") == "new", "insert")
check(byID["3"]?.cell(for: "city") == "odd", "insert_only keeps existing")

let console = try await client.execute(QdrantConsoleParser.parse("POST /collections/tablepro_probe/points/query\n{\"query\": [1, 0], \"limit\": 2, \"with_vector\": true, \"with_payload\": true}")!)
let hits = QdrantPoint.list(fromResponse: console.json) ?? []
print("query columns", QdrantPoint.columns(of: hits, collection: collection), hits.first?.row(columns: QdrantPoint.columns(of: hits, collection: collection)) ?? [])
check(hits.count == 2 && hits[0].score != nil, "vector query has scores")

_ = try await client.execute(QdrantConsoleRequest(method: "PUT", path: "/collections/tablepro_probe/points?wait=true", body: #"{"points":[{"id":5000,"vector":[1,1],"payload":{"late":true,"id":"ext-1"}}]}"#))
var widened = collection
for try await page in client.pointPages(collection: "tablepro_probe", pageSize: 60, withVector: false) {
    check(page.allSatisfy { $0.vector == nil }, "payload-only pass has no vectors")
    widened = widened.including(page)
}
let wcols = QdrantSchema.columns(for: widened).map(\.name)
print("export columns", wcols)
check(wcols.contains("late") && wcols.contains("payload.id"), "late and reserved keys found")
let lateFilter = try QdrantFilterBuilder.filter([QdrantFilterSpec(column: "payload.id", op: "=", value: "ext-1")], logicMode: "AND", collection: widened)
check(try await client.count(collection: "tablepro_probe", filter: lateFilter) == 1, "filter on payload.id")
var exported = 0
for try await page in client.pointPages(collection: "tablepro_probe", pageSize: 60) { exported += page.count }
check(exported == 251, "export all")

let truncate = QdrantOperations.deleteAllPoints(collection: "tablepro_probe")!
_ = try await client.execute(QdrantConsoleParser.parse(truncate)!)
check(try await client.count(collection: "tablepro_probe", filter: nil) == 0, "truncate")
_ = try await client.execute(QdrantConsoleParser.parse(QdrantOperations.deleteCollection(named: "tablepro_probe", objectType: "TABLE")!)!)
check(!(try await client.collectionNames().contains("tablepro_probe")), "drop")
do {
    _ = try await client.collection(named: "tablepro_probe_missing")
    check(false, "missing collection reports an error")
} catch {
    check(error.localizedDescription.contains("doesn't exist"), "missing collection reports an error")
}
exit(failures == 0 ? 0 : 1)
