import Foundation
import TableProQdrantCore

// Measures, against a live node, the Qdrant behavior TableProQdrantCore hard-codes.
// Run through check-qdrant.sh, which builds it against this checkout's TableProCore.

var failures = 0
@MainActor func check(_ ok: Bool, _ label: String) {
    print(ok ? "PASS" : "FAIL", label)
    if !ok { failures += 1 }
}

final class ProbeTransport: QdrantTransport, @unchecked Sendable {
    func send(_ request: QdrantHTTPRequest) async throws -> QdrantHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        request.headers.forEach { urlRequest.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        return QdrantHTTPResponse(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    func cancelAll() {}
}

let env = ProcessInfo.processInfo.environment
let settings = QdrantConnectionSettings(
    host: env["QDRANT_HOST"] ?? "127.0.0.1",
    port: Int(env["QDRANT_PORT"] ?? "") ?? 6_333,
    usesTLS: false,
    apiKey: env["QDRANT_API_KEY"] ?? ""
)
let client = QdrantClient(settings: settings, transport: ProbeTransport(), timeout: { 10 })
try await client.connect(requestTimeout: { 10 })
print("version", client.serverVersion ?? "nil")

let name = "tablepro_probe"
let base = "/collections/\(name)"
func request(_ text: String?) -> QdrantConsoleRequest {
    guard let text, let request = QdrantConsoleParser.parse(text) else { fatalError("not a request: \(text ?? "nil")") }
    return request
}
func run(_ text: String?) async throws -> QdrantHTTPResponse {
    try await client.execute(request(text))
}

_ = try? await run("DELETE \(base)")
_ = try await run(#"PUT \#(base) {"vectors":{"size":2,"distance":"Dot"},"sparse_vectors":{"sp":{}}}"#)
var points: [[String: Any]] = []
for i in 1...250 {
    var payload: [String: Any] = ["city": i % 2 == 0 ? "even" : "odd", "body": "Hello World \(i)", "f": Double(i) + 0.5]
    if i <= 200 { payload["n"] = i }
    if i == 7 { payload["note"] = NSNull() }
    if i == 8 { payload["note"] = "" }
    payload["meta"] = ["source": "doc\(i).pdf"]
    payload["a.b"] = "dotted"
    points.append(["id": i, "vector": ["": [Double(i), 1]], "payload": payload])
}
_ = try await run("PUT \(base)/points?wait=true\n" + (try QdrantJSON.text(["points": points])))
for (field, schema) in [("n", "integer"), ("f", "float"), ("city", "keyword"), ("meta.source", "keyword")] {
    _ = try await run(#"PUT \#(base)/index?wait=true {"field_name":"\#(field)","field_schema":"\#(schema)"}"#)
}

check(try await client.collectionNames().contains(name), "lists collection")
let collection = try await client.collection(named: name)
let columns = QdrantSchema.columns(for: collection)
print("columns", columns.map { "\($0.name):\($0.type)" })
check(collection.pointsCount == 250, "points_count")
check(!columns.contains { $0.name == "meta.source" } && collection.indexes.contains { $0.path == "meta.source" }, "nested index path is an index, not a column")
check(columns.contains { $0.name == "vector" && $0.type == "vector(2)" } && columns.contains { $0.name == "vector.sp" }, "vector columns typed")

let cache = QdrantPagingCache()
let p0 = try await client.scrollPage(collection: name, filter: nil, offset: 0, limit: 100, cache: cache)
let p1 = try await client.scrollPage(collection: name, filter: nil, offset: 100, limit: 100, cache: cache)
let p2 = try await client.scrollPage(collection: name, filter: nil, offset: 200, limit: 100, cache: cache)
check(p0.first?.idText == "1" && p1.first?.idText == "101" && p2.count == 50 && p2.last?.idText == "250", "paging forward")
let jump = try await client.scrollPage(collection: name, filter: nil, offset: 170, limit: 10, cache: QdrantPagingCache())
check(jump.map { $0.idText ?? "" } == (171...180).map(String.init), "jump walks to offset")
check(try await client.scrollPage(collection: name, filter: nil, offset: 400, limit: 10, cache: cache).isEmpty, "past end")

func filtered(_ specs: [QdrantFilterSpec], _ mode: String = "AND") async throws -> Int {
    let filter = try QdrantFilterBuilder.filter(specs, logicMode: mode, collection: collection)
    return try await client.count(collection: name, filter: filter)
}
check(try await filtered([QdrantFilterSpec(column: "city", op: "=", value: "even")]) == 125, "match keyword")
check(try await filtered([QdrantFilterSpec(column: "n", op: "BETWEEN", value: "10,19", secondValue: "19")]) == 10, "between")
check(try await filtered([QdrantFilterSpec(column: "n", op: ">", value: "190"), QdrantFilterSpec(column: "city", op: "!=", value: "even")]) == 5, "and with not")
check(try await filtered([QdrantFilterSpec(column: "n", op: "<", value: "3"), QdrantFilterSpec(column: "n", op: ">", value: "198")], "OR") == 4, "or")
check(try await filtered([QdrantFilterSpec(column: "body", op: "CONTAINS", value: "world")]) == 250, "contains without a text index matches words")
check(try await filtered([QdrantFilterSpec(column: "id", op: "IN", value: "1,2,3")]) == 3, "has_id")
check(try await filtered([QdrantFilterSpec(column: "n", op: "IN", value: "1,2,300")]) == 2, "match any")
check(try await filtered([QdrantFilterSpec(column: "f", op: "IN", value: "1.5, 2.5")]) == 2, "IN on floats")
check(try await filtered([QdrantFilterSpec(column: "f", op: "NOT IN", value: "1.5")]) == 249, "NOT IN on floats")
check(try await filtered([QdrantFilterSpec(column: "n", op: "IS NULL", value: "")]) == 50, "IS NULL counts missing keys")
check(try await filtered([QdrantFilterSpec(column: "note", op: "IS NULL", value: "")]) == 249, "IS NULL counts null and missing")
check(try await filtered([QdrantFilterSpec(column: "note", op: "IS EMPTY", value: "")]) == 250, "IS EMPTY adds the empty string")
check(try await filtered([QdrantFilterSpec(column: "a.b", op: "=", value: "dotted")]) == 250, "dotted top-level key")

func sorted(_ offset: Int, _ limit: Int, ascending: Bool = false) async throws -> [String] {
    try await client.sortedPage(
        collection: name, filter: nil, column: "n", key: "\"n\"", ascending: ascending,
        offset: offset, limit: limit, cache: cache
    ).map { $0.idText ?? "" }
}
check(try await sorted(5, 3) == ["195", "194", "193"], "order_by with offset")
check(try await sorted(198, 4) == ["2", "1", "201", "202"], "points without the key follow the ordered ones")
check(try await sorted(248, 10) == ["249", "250"], "every point reachable when sorted")
_ = try await run(#"POST \#(base)/points/payload?wait=true {"payload":{"n":[1,2]},"points":[3]}"#)
do {
    _ = try await client.sortedPage(collection: name, filter: nil, column: "n", key: "\"n\"", ascending: true, offset: 0, limit: 5, cache: QdrantPagingCache())
    check(false, "list values refuse the sort")
} catch {
    check(error.localizedDescription.contains("list"), "list values refuse the sort")
}
_ = try await run(#"POST \#(base)/points/payload?wait=true {"payload":{"n":3},"points":[3]}"#)

let types = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0.type) })
let writes = try QdrantRowWriter.writes(collection: name, changes: [
    QdrantRowChange(kind: .update, rowIndex: 0, id: "1", cells: [
        QdrantCell(column: "city", text: "edited"), QdrantCell(column: "n", text: "1000"),
        QdrantCell(column: "vector", text: "[9, 9]"), QdrantCell(column: "vector.sp", text: #"{"indices":[2],"values":[0.5]}"#)
    ]),
    QdrantRowChange(kind: .delete, rowIndex: 1, id: "2"),
    QdrantRowChange(kind: .insert, rowIndex: 2, id: nil, cells: [
        QdrantCell(column: "id", text: "999"), QdrantCell(column: "city", text: "new"), QdrantCell(column: "vector", text: "[1, 2]")
    ])
], typeName: { types[$0] })
for write in writes {
    if let lookup = write.mustFindNothing {
        check(QdrantPoint.list(fromResponse: try await run(lookup.text).json)?.isEmpty == true, "insert lookup finds a free id")
    }
    _ = try await run(write.request.text)
}
let taken = try QdrantRowWriter.writes(collection: name, changes: [
    QdrantRowChange(kind: .insert, rowIndex: 0, id: nil, cells: [QdrantCell(column: "id", text: "3")])
], typeName: { types[$0] })
check(QdrantPoint.list(fromResponse: try await run(taken[0].mustFindNothing?.text).json)?.count == 1, "insert lookup finds a taken id")

let after = try await run(#"POST \#(base)/points {"ids":[1,2,999],"with_payload":true,"with_vector":true}"#)
let byID = Dictionary(uniqueKeysWithValues: (QdrantPoint.list(fromResponse: after.json) ?? []).map { ($0.idText ?? "", $0) })
check(byID["1"]?.cell(for: "city") == "edited" && byID["1"]?.cell(for: "n") == "1000", "set payload typed")
check(byID["1"]?.cell(for: "vector") == "[9,9]" && byID["1"]?.cell(for: "vector.sp") == #"{"indices":[2],"values":[0.5]}"#, "vectors updated")
check(byID["2"] == nil, "delete")
check(byID["999"]?.cell(for: "city") == "new" && byID["999"]?.cell(for: "vector") == "[1,2]", "insert with vector")
let cleared = try QdrantRowWriter.writes(collection: name, changes: [
    QdrantRowChange(kind: .update, rowIndex: 0, id: "1", cells: [QdrantCell(column: "vector.sp", text: nil)])
], typeName: { types[$0] })
_ = try await run(cleared[0].request.text)
let afterClear = QdrantPoint.list(fromResponse: try await run(#"POST \#(base)/points {"ids":[1],"with_vector":true}"#).json)
check(afterClear?.first?.cell(for: "vector.sp") == nil, "NULL removes a vector")

let facet = request(#"POST \#(base)/facet {"key":"city"}"#)
check(facet.kind.tier == .read, "facet is a read")
check(((try await client.execute(facet).json as? [String: Any])?["result"]) != nil, "facet route answers")

let console = try await run("POST \(base)/points/query {\"query\": [1, 0],\n\"limit\": 2, \"with_vector\": true, \"with_payload\": true}")
let hits = QdrantPoint.list(fromResponse: console.json) ?? []
check(hits.count == 2 && hits[0].score != nil, "vector query with a body over two lines has scores")

var widened = collection
for try await page in client.pointPages(collection: name, pageSize: 60, withVector: false) {
    widened = widened.including(page)
}
var exported = 0
for try await page in client.pointPages(collection: name, pageSize: 60) { exported += page.count }
check(exported == 250, "export all")

_ = try await run(QdrantOperations.deleteAllPoints(collection: name))
check(try await client.count(collection: name, filter: nil) == 0, "truncate")
_ = try await run(QdrantOperations.deleteCollection(named: name, objectType: "TABLE"))
check(!(try await client.collectionNames().contains(name)), "drop")
exit(failures == 0 ? 0 : 1)
