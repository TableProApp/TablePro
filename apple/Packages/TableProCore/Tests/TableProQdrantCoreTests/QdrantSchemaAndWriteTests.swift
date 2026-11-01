import Foundation
@testable import TableProQdrantCore
import Testing

struct QdrantSchemaAndWriteTests {
    private func info(vectors: Any, payloadSchema: [String: Any] = [:]) -> [String: Any] {
        ["result": [
            "points_count": 4,
            "config": ["params": ["vectors": vectors]],
            "payload_schema": payloadSchema
        ]]
    }

    private func point(_ json: String) throws -> QdrantPoint {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(QdrantPoint.parse(object))
    }

    @Test("Columns are the id, indexed fields, sampled fields, then vectors")
    func columns() throws {
        let sample = [
            try point(#"{"id":1,"payload":{"city":"Berlin","count":3,"meta":{"x":1}}}"#),
            try point(#"{"id":2,"payload":{"count":3.5,"tags":["a"]}}"#)
        ]
        let collection = QdrantCollection.parse(
            name: "docs",
            info: info(vectors: ["size": 4, "distance": "Cosine"], payloadSchema: ["city": ["data_type": "keyword"]]),
            sample: sample
        )
        #expect(QdrantSchema.columns(for: collection).map(\.name) == ["id", "city", "count", "meta", "tags", "vector"])
        #expect(collection.fieldType(of: "city") == .keyword)
        #expect(collection.fieldType(of: "count") == .float)
        #expect(collection.fieldType(of: "meta") == .object)
        #expect(collection.pointsCount == 4)
        #expect(QdrantSchema.immutableColumns(for: collection) == ["id", "vector"])
    }

    @Test("A payload key named like a point column shows as payload.<key> and maps back")
    func reservedPayloadKeys() throws {
        let row = try point(#"{"id":7,"payload":{"id":"external-1","vector":"text","city":"Berlin"},"vector":[1,2]}"#)
        let collection = QdrantCollection.parse(name: "docs", info: info(vectors: ["size": 2]), sample: [row])
        let columns = QdrantSchema.columns(for: collection).map(\.name)
        #expect(columns == ["id", "city", "payload.id", "payload.vector", "vector"])
        #expect(row.row(columns: columns) == ["7", "Berlin", "external-1", "text", "[1,2]"])

        let condition = try QdrantFilterBuilder.condition(
            for: QdrantFilterSpec(column: "payload.id", op: "=", value: "external-1"),
            collection: collection
        )
        #expect(canonical(condition) == #"{"key":"id","match":{"value":"external-1"}}"#)

        let batch = QdrantStatementGenerator.generate(collection: collection, changes: [
            QdrantTrackedChange(kind: .update, id: "7", cellChanges: [QdrantCellChange(column: "payload.id", newText: "external-2")])
        ])
        #expect(batch.requests.first?.body == #"{"payload":{"id":"external-2"},"points":[7]}"#)
    }

    @Test("Keys outside the sample join the collection, and a key first seen as null takes its later type")
    func includingLaterPoints() throws {
        let sample = [try point(#"{"id":1,"payload":{"city":"Berlin","rank":null}}"#)]
        let collection = QdrantCollection.parse(name: "docs", info: info(vectors: ["size": 2]), sample: sample)
        let widened = collection.including([try point(#"{"id":2,"payload":{"late":true,"rank":3}}"#)])
        #expect(widened.payloadFields.map(\.name) == ["city", "rank", "late"])
        #expect(widened.fieldType(of: "rank") == .integer)
        #expect(widened.fieldType(of: "late") == .bool)
    }

    @Test("Named and sparse vectors each get a read-only column")
    func namedVectors() throws {
        var json = info(vectors: ["image": ["size": 2], "text": ["size": 3]])
        var result = try #require(json["result"] as? [String: Any])
        var config = try #require(result["config"] as? [String: Any])
        var params = try #require(config["params"] as? [String: Any])
        params["sparse_vectors"] = ["keywords": [String: Any]()]
        config["params"] = params
        result["config"] = config
        json["result"] = result

        let collection = QdrantCollection.parse(name: "docs", info: json, sample: [])
        #expect(collection.vectorColumns == ["vector.image", "vector.text", "vector.keywords"])

        let row = try point(#"{"id":"5c56c793-69f3-4fbf-87e6-c4bf54c28c26","vector":{"image":[0.5,1],"keywords":{"indices":[1],"values":[0.5]}}}"#)
        #expect(row.cell(for: "id") == "5c56c793-69f3-4fbf-87e6-c4bf54c28c26")
        #expect(row.cell(for: "vector.image") == "[0.5,1]")
        #expect(row.cell(for: "vector.keywords") == #"{"indices":[1],"values":[0.5]}"#)
        #expect(row.cell(for: "vector.text") == nil)
    }

    @Test("A query result shows the score after the id")
    func queryColumns() throws {
        let json = try JSONSerialization.jsonObject(with: Data(
            #"{"result":{"points":[{"id":1,"score":0.9,"payload":{"city":"Berlin"},"vector":[1,2]}]},"status":"ok"}"#.utf8
        ))
        let points = try #require(QdrantPoint.list(fromResponse: json))
        let columns = QdrantPoint.columns(of: points, collection: nil)
        #expect(columns == ["id", "score", "city", "vector"])
        #expect(points[0].row(columns: columns) == ["1", "0.9", "Berlin", "[1,2]"])
        #expect(QdrantPoint.list(fromResponse: ["result": ["count": 3]]) == nil)
    }

    @Test("A payload edit is a set-payload request typed by the column")
    func update() throws {
        let batch = QdrantStatementGenerator.generate(collection: sampleCollection, changes: [
            QdrantTrackedChange(kind: .update, id: "7", cellChanges: [
                QdrantCellChange(column: "note", newText: "42"),
                QdrantCellChange(column: "count", newText: "42"),
                QdrantCellChange(column: "vector", newText: "[1]")
            ])
        ])
        let request = try #require(batch.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/collections/docs/points/payload?wait=true")
        #expect(request.body == #"{"payload":{"count":42,"note":"42"},"points":[7]}"#)
    }

    @Test("A delete names the point, and a row without an id is skipped, not sent")
    func delete() throws {
        let uuid = "5c56c793-69f3-4fbf-87e6-c4bf54c28c26"
        let batch = QdrantStatementGenerator.generate(collection: sampleCollection, changes: [
            QdrantTrackedChange(kind: .delete, id: uuid),
            QdrantTrackedChange(kind: .delete, id: nil),
            QdrantTrackedChange(kind: .update, id: "1", cellChanges: [QdrantCellChange(column: "id", newText: "2")])
        ])
        #expect(batch.requests.map(QdrantWriteCodec.encode) == [
            "POST /collections/docs/points/delete?wait=true\n{\"points\":[\"\(uuid)\"]}"
        ])
        #expect(batch.skipped.map(\.reason) == [.missingID, .noEditableColumns])
    }

    @Test("An insert never overwrites an existing id and gets a UUID when left blank")
    func insert() throws {
        let batch = QdrantStatementGenerator.generate(
            collection: sampleCollection,
            changes: [QdrantTrackedChange(kind: .insert, id: nil, values: ["city": "Hanoi", "active": "true"])],
            uuid: { "00000000-0000-0000-0000-000000000001" }
        )
        let request = try #require(batch.requests.first)
        #expect(request.method == "PUT")
        #expect(request.path == "/collections/docs/points?wait=true")
        #expect(request.body == #"{"points":[{"id":"00000000-0000-0000-0000-000000000001","payload":{"active":true,"city":"Hanoi"},"vector":{}}],"update_mode":"insert_only"}"#)
    }

    @Test("Browse requests round-trip through their tag")
    func browseRoundTrip() throws {
        let request = QdrantBrowseRequest(
            collection: "docs",
            offset: 200,
            limit: 100,
            sort: QdrantSortSpec(column: "pop", ascending: false),
            filters: [QdrantFilterSpec(column: "count", op: "BETWEEN", value: "1,5", secondValue: "5")],
            logicMode: "OR"
        )
        #expect(QdrantBrowseQuery.parse(QdrantBrowseQuery.encode(request)) == request)
    }

    @Test("A sorted page uses order_by with a numeric offset")
    func sortedBody() {
        let request = QdrantBrowseRequest(collection: "docs", offset: 50, limit: 25, sort: nil, filters: [], logicMode: "AND")
        let body = QdrantBrowseQuery.queryBody(for: request, filter: nil, sort: QdrantSortSpec(column: "pop", ascending: false))
        #expect(canonical(body) == #"{"limit":25,"offset":50,"query":{"order_by":{"direction":"desc","key":"pop"}},"with_payload":true,"with_vector":true}"#)
    }

    @Test("The console reads a request line with its body below or beside it")
    func console() {
        let below = QdrantConsoleParser.parse("POST /collections/docs/points/query\n{\"limit\": 3}")
        #expect(below == QdrantConsoleRequest(method: "POST", path: "/collections/docs/points/query", body: "{\"limit\": 3}"))
        let inline = QdrantConsoleParser.parse("post /collections/docs/points/count {\"exact\": true}")
        #expect(inline?.method == "POST")
        #expect(inline?.body == "{\"exact\": true}")
        #expect(QdrantConsoleParser.parse("SELECT 1") == nil)
        #expect(QdrantConsoleParser.parse("GET collections") == nil)
    }

    @Test("Only the read endpoints count as reads")
    func readEndpoints() {
        #expect(QdrantConsoleRequest(method: "POST", path: "/collections/docs/points/query", body: nil).isRead)
        #expect(QdrantConsoleRequest(method: "POST", path: "/collections/docs/points", body: nil).isRead)
        #expect(!QdrantConsoleRequest(method: "POST", path: "/collections/docs/points/delete?wait=true", body: nil).isRead)
        #expect(!QdrantConsoleRequest(method: "PUT", path: "/collections/docs/points", body: nil).isRead)
    }

    @Test("Point ids parse back to the kind Qdrant expects")
    func pointIDs() {
        #expect(QdrantPointID.json(from: "42") as? NSNumber == 42)
        #expect(QdrantPointID.json(from: "5C56C793-69F3-4FBF-87E6-C4BF54C28C26") as? String == "5c56c793-69f3-4fbf-87e6-c4bf54c28c26")
        #expect(QdrantPointID.json(from: "-1") == nil)
        #expect(QdrantPointID.json(from: "abc") == nil)
    }

    @Test("A cell is written back as its column's type")
    func parsedValues() {
        #expect(QdrantJSON.parsedValue("42", fieldType: .keyword) as? String == "42")
        #expect(QdrantJSON.parsedValue("42", fieldType: .integer) as? Int64 == 42)
        #expect(QdrantJSON.parsedValue("false", fieldType: .bool) as? Bool == false)
        #expect((QdrantJSON.parsedValue(#"["a"]"#, fieldType: .array) as? [String]) == ["a"])
        #expect(QdrantJSON.parsedValue("not json", fieldType: .object) as? String == "not json")
    }
}
