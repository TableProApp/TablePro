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
    if i <= 100 { payload["when"] = String(format: "2024-01-01T%02d:%02d:00Z", i / 60, i % 60) }
    if i == 7 { payload["note"] = NSNull() }
    if i == 8 { payload["note"] = "" }
    if i == 9 { payload["city"] = 42 }
    if i == 10 { payload["mixed"] = "42" }
    if i == 11 { payload["mixed"] = 42 }
    if i == 12 { payload["mixed"] = ["42"] }
    payload["meta"] = ["source": "doc\(i).pdf"]
    payload["a.b"] = "dotted"
    points.append(["id": i, "vector": ["": [Double(i), 1]], "payload": payload])
}
_ = try await run("PUT \(base)/points?wait=true\n" + (try QdrantJSON.text(["points": points])))
for (field, schema) in [("n", "integer"), ("f", "float"), ("when", "datetime"), ("city", "keyword"), ("meta.source", "keyword")] {
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
let p0 = try await client.pointPage(collection: name, filter: nil, offset: 0, limit: 100)
let p1 = try await client.pointPage(collection: name, filter: nil, offset: 100, limit: 100)
let p2 = try await client.pointPage(collection: name, filter: nil, offset: 200, limit: 100)
check(p0.first?.idText == "1" && p1.first?.idText == "101" && p2.count == 50 && p2.last?.idText == "250", "paging forward")
let jump = try await client.pointPage(collection: name, filter: nil, offset: 170, limit: 10)
check(jump.map { $0.idText ?? "" } == (171...180).map(String.init), "jump walks to offset")
check(try await client.pointPage(collection: name, filter: nil, offset: 400, limit: 10).isEmpty, "past end")
_ = try await run(#"POST \#(base)/points/delete?wait=true {"points":[50]}"#)
let shifted = try await client.pointPage(collection: name, filter: nil, offset: 100, limit: 2)
check(shifted.map { $0.idText ?? "" } == ["102", "103"], "a page after another client's delete starts at the right row")
_ = try await run(#"PUT \#(base)/points?wait=true {"points":[{"id":50,"vector":[50,1],"payload":{"city":"even","body":"Hello World 50","f":50.5,"n":50,"meta":{"source":"doc50.pdf"},"a.b":"dotted","when":"2024-01-01T00:50:00Z"}}]}"#)

func filtered(_ specs: [QdrantFilterSpec], _ mode: String = "AND") async throws -> Int {
    let filter = try QdrantFilterBuilder.filter(specs, logicMode: mode)
    return try await client.count(collection: name, filter: filter)
}
check(try await filtered([QdrantFilterSpec(column: "city", op: "=", value: "even")]) == 125, "match keyword")
check(try await filtered([QdrantFilterSpec(column: "city", op: "=", value: "42")]) == 1, "a number stored under a keyword index is found")
check(try await filtered([QdrantFilterSpec(column: "n", op: "BETWEEN", value: "10,19", secondValue: "19")]) == 10, "between")
check(try await filtered([QdrantFilterSpec(column: "n", op: ">", value: "190"), QdrantFilterSpec(column: "city", op: "!=", value: "even")]) == 5, "and with not")
check(try await filtered([QdrantFilterSpec(column: "n", op: "<", value: "3"), QdrantFilterSpec(column: "n", op: ">", value: "198")], "OR") == 4, "or")
check(try await filtered([QdrantFilterSpec(column: "body", op: "CONTAINS", value: "world")]) == 250, "contains without a text index matches words")
check(try await filtered([QdrantFilterSpec(column: "id", op: "IN", value: "1,2,3")]) == 3, "has_id")
let searchAll = [
    QdrantFilterSpec(column: "id", op: "CONTAINS", value: "Berlin"),
    QdrantFilterSpec(column: "city", op: "CONTAINS", value: "even")
]
check(try await filtered(searchAll, "OR") == 125, "search all rows skips the id column")
let searchNumbers = [
    QdrantFilterSpec(column: "n", op: "CONTAINS", value: "5"),
    QdrantFilterSpec(column: "vector.sp", op: "CONTAINS", value: "5"),
    QdrantFilterSpec(column: "city", op: "CONTAINS", value: "even")
]
check(try await filtered(searchNumbers, "OR") == 125, "search all rows runs on number and vector columns")
let evenFilter = try QdrantFilterBuilder.filter([QdrantFilterSpec(column: "city", op: "=", value: "even")], logicMode: "AND")
let evenBefore = try await client.pointPage(collection: name, filter: evenFilter, offset: 10, limit: 2)
_ = try await run(#"POST \#(base)/points/payload?wait=true {"payload":{"city":"odd"},"points":[2]}"#)
let evenAfter = try await client.pointPage(collection: name, filter: evenFilter, offset: 10, limit: 2)
_ = try await run(#"POST \#(base)/points/payload?wait=true {"payload":{"city":"even"},"points":[2]}"#)
check(evenBefore.map { $0.idText ?? "" } == ["22", "24"] && evenAfter.map { $0.idText ?? "" } == ["24", "26"], "a filtered page follows another client's payload change")
check(try await filtered([QdrantFilterSpec(column: "n", op: "IN", value: "1,2,300")]) == 2, "match any")
check(try await filtered([QdrantFilterSpec(column: "f", op: "IN", value: "1.5, 2.5")]) == 2, "IN on floats")
check(try await filtered([QdrantFilterSpec(column: "f", op: "NOT IN", value: "1.5")]) == 249, "NOT IN on floats")
check(try await filtered([QdrantFilterSpec(column: "n", op: "IS NULL", value: "")]) == 50, "IS NULL counts missing keys")
check(try await filtered([QdrantFilterSpec(column: "note", op: "IS NULL", value: "")]) == 249, "IS NULL counts null and missing")
check(try await filtered([QdrantFilterSpec(column: "note", op: "IS EMPTY", value: "")]) == 250, "IS EMPTY adds the empty string")
check(try await filtered([QdrantFilterSpec(column: "a.b", op: "=", value: "dotted")]) == 250, "dotted top-level key")
check(try await filtered([QdrantFilterSpec(column: "mixed", op: "=", value: "42")]) == 3, "an unindexed value matches as text, number and list")
check(try await filtered([QdrantFilterSpec(column: "mixed", op: "NOT IN", value: "42, 7")]) == 247, "NOT IN excludes every spelling")

func sorted(_ offset: Int, _ limit: Int, ascending: Bool = false) async throws -> [String] {
    try await client.sortedPage(
        collection: name, filter: nil, column: "n", key: "\"n\"", ascending: ascending,
        offset: offset, limit: limit, cache: cache
    ).map { $0.idText ?? "" }
}
check(try await sorted(5, 3) == ["195", "194", "193"], "order_by with offset")
check(try await sorted(198, 4) == ["2", "1", "201", "202"], "points without the key follow the ordered ones")
check(try await sorted(248, 10) == ["249", "250"], "every point reachable when sorted")
let byDate = { (offset: Int, limit: Int) in
    try await client.sortedPage(
        collection: name, filter: nil, column: "when", key: "\"when\"", ascending: false,
        offset: offset, limit: limit, cache: cache
    ).map { $0.idText ?? "" }
}
check(try await byDate(0, 2) == ["100", "99"], "datetime sort orders by date")
check(try await byDate(99, 3) == ["1", "101", "102"], "datetime sort puts undated points after")
_ = try await run(#"POST \#(base)/points/payload?wait=true {"payload":{"n":[1,2]},"points":[3]}"#)
do {
    _ = try await client.sortedPage(collection: name, filter: nil, column: "n", key: "\"n\"", ascending: true, offset: 0, limit: 5, cache: QdrantPagingCache())
    check(false, "list values refuse the sort")
} catch {
    check(error.localizedDescription.contains("list"), "list values refuse the sort")
}
_ = try await run(#"POST \#(base)/points/payload?wait=true {"payload":{"n":3},"points":[3]}"#)
do {
    _ = try await client.sortedPage(collection: name, filter: nil, column: "city", key: "\"city\"", ascending: true, offset: 0, limit: 5, cache: QdrantPagingCache())
    check(false, "a keyword field refuses the sort")
} catch {
    check(error.localizedDescription.contains("range index"), "a keyword field refuses the sort")
}

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
], serverVersion: client.serverVersion, typeName: { types[$0] })
for write in writes {
    if let lookup = write.mustFindNothing {
        check(QdrantPoint.list(fromResponse: try await run(lookup.text).json)?.isEmpty == true, "insert lookup finds a free id")
    }
    _ = try await run(write.request.text)
}
let taken = try QdrantRowWriter.writes(collection: name, changes: [
    QdrantRowChange(kind: .insert, rowIndex: 0, id: nil, cells: [QdrantCell(column: "id", text: "3")])
], serverVersion: client.serverVersion, typeName: { types[$0] })
check(QdrantPoint.list(fromResponse: try await run(taken[0].mustFindNothing?.text).json)?.count == 1, "insert lookup finds a taken id")
_ = try await run(taken[0].request.text)
let untouched = QdrantPoint.list(fromResponse: try await run(#"POST \#(base)/points {"ids":[3],"with_payload":true,"with_vector":true}"#).json)
check(untouched?.first?.cell(for: "city") == "odd" && untouched?.first?.cell(for: "vector") == "[3,1]", "insert leaves a taken id untouched")

let raced = try QdrantRowWriter.writes(collection: name, changes: [
    QdrantRowChange(kind: .insert, rowIndex: 0, id: nil, cells: [QdrantCell(column: "id", text: "777"), QdrantCell(column: "city", text: "ours")])
], serverVersion: client.serverVersion, typeName: { types[$0] })[0]
check(QdrantPoint.list(fromResponse: try await run(raced.mustFindNothing?.text).json)?.isEmpty == true, "raced insert passes its lookup")
_ = try await run(#"PUT \#(base)/points?wait=true {"points":[{"id":777,"vector":[7,7],"payload":{"city":"theirs"}}]}"#)
_ = try await run(raced.request.text)
guard let racedCheck = raced.landedCheck.flatMap(QdrantInsertCheck.decode) else { fatalError("insert has no landed check") }
let held = QdrantPoint.list(fromResponse: try await run(#"POST \#(base)/points {"ids":[777],"with_payload":true,"with_vector":true}"#).json)?.first
check(!QdrantInsertCheck.landed(held, payload: racedCheck.payload, vectors: racedCheck.vectors), "an insert that lost a race to the same id is caught after the write")
_ = try await run(#"POST \#(base)/points/delete?wait=true {"points":[777]}"#)
let after = try await run(#"POST \#(base)/points {"ids":[1,2,999],"with_payload":true,"with_vector":true}"#)
let byID = Dictionary(uniqueKeysWithValues: (QdrantPoint.list(fromResponse: after.json) ?? []).map { ($0.idText ?? "", $0) })
check(byID["1"]?.cell(for: "city") == "edited" && byID["1"]?.cell(for: "n") == "1000", "set payload typed")
check(byID["1"]?.cell(for: "vector") == "[9,9]" && byID["1"]?.cell(for: "vector.sp") == #"{"indices":[2],"values":[0.5]}"#, "vectors updated")
check(byID["2"] == nil, "delete")
check(byID["999"]?.cell(for: "city") == "new" && byID["999"]?.cell(for: "vector") == "[1,2]", "insert with vector")
let cleared = try QdrantRowWriter.writes(collection: name, changes: [
    QdrantRowChange(kind: .update, rowIndex: 0, id: "1", cells: [QdrantCell(column: "vector.sp", text: nil)])
], serverVersion: client.serverVersion, typeName: { types[$0] })
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
