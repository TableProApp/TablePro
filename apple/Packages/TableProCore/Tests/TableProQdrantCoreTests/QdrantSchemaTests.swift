import Foundation
@testable import TableProQdrantCore
import Testing

struct QdrantSchemaTests {
    private func info(vectors: Any, sparse: [String: Any]? = nil, payloadSchema: [String: Any] = [:]) -> [String: Any] {
        var params: [String: Any] = ["vectors": vectors]
        params["sparse_vectors"] = sparse
        return ["result": ["points_count": 4, "config": ["params": params], "payload_schema": payloadSchema]]
    }

    private func point(_ json: String) throws -> QdrantPoint {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(QdrantPoint.parse(object))
    }

    @Test("Columns are the id, indexed fields, sampled fields, then vectors typed by their size")
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
        let columns = QdrantSchema.columns(for: collection)
        #expect(columns.map(\.name) == ["id", "city", "count", "meta", "tags", "vector"])
        #expect(columns.map(\.type) == ["id", "keyword", "float", "object", "array", "vector(4)"])
        #expect(collection.pointsCount == 4)
    }

    @Test("A nested index path is an index, not a column that would always read NULL")
    func nestedIndexPaths() throws {
        let collection = QdrantCollection.parse(
            name: "docs",
            info: info(vectors: ["size": 2], payloadSchema: [
                "metadata.source": ["data_type": "keyword"],
                "tags[]": ["data_type": "keyword"],
                "\"a.b\"": ["data_type": "integer"],
                "rank": ["data_type": "integer"]
            ]),
            sample: [try point(#"{"id":1,"payload":{"metadata":{"source":"a.pdf"},"tags":["x"]}}"#)]
        )
        #expect(QdrantSchema.columns(for: collection).map(\.name) == ["id", "a.b", "rank", "metadata", "tags", "vector"])
        #expect(collection.indexes.map(\.path) == ["\"a.b\"", "metadata.source", "rank", "tags[]"])
        #expect(collection.fieldType(ofColumn: "metadata") == .object)
    }

    @Test("A payload key named like a point column shows as payload.<key> and maps back")
    func reservedPayloadKeys() throws {
        let row = try point(#"{"id":7,"payload":{"id":"external-1","vector":"text","city":"Berlin"},"vector":[1,2]}"#)
        let collection = QdrantCollection.parse(name: "docs", info: info(vectors: ["size": 2]), sample: [row])
        let columns = QdrantSchema.columns(for: collection).map(\.name)
        #expect(columns == ["id", "city", "payload.id", "payload.vector", "vector"])
        #expect(row.row(columns: columns) == ["7", "Berlin", "external-1", "text", "[1,2]"])
        #expect(QdrantSchema.payloadKey(forColumn: "payload.id") == "id")
        #expect(QdrantSchema.payloadKey(forColumn: "payload.city") == "payload.city")
    }

    @Test("Keys outside the sample join the collection, and a key first seen as null takes its later type")
    func includingLaterPoints() throws {
        let sample = [try point(#"{"id":1,"payload":{"city":"Berlin","rank":null}}"#)]
        let collection = QdrantCollection.parse(name: "docs", info: info(vectors: ["size": 2]), sample: sample)
        let widened = collection.including([try point(#"{"id":2,"payload":{"late":true,"rank":3}}"#)])
        #expect(widened.payloadFields.map(\.name) == ["city", "rank", "late"])
        #expect(widened.fieldType(ofColumn: "rank") == .integer)
        #expect(widened.fieldType(ofColumn: "late") == .bool)
    }

    @Test("Named, multi and sparse vectors each get a column typed by their kind")
    func namedVectors() throws {
        let collection = QdrantCollection.parse(
            name: "docs",
            info: info(
                vectors: ["image": ["size": 2], "text": ["size": 3, "multivector_config": ["comparator": "max_sim"]]],
                sparse: ["keywords": [String: Any]()]
            )
        )
        let columns = QdrantSchema.columns(for: collection)
        #expect(columns.map(\.name) == ["id", "vector.image", "vector.text", "vector.keywords"])
        #expect(columns.map(\.type) == ["id", "vector(2)", "multivector", "sparse_vector"])

        let row = try point(#"{"id":"5c56c793-69f3-4fbf-87e6-c4bf54c28c26","vector":{"image":[0.5,1],"keywords":{"indices":[1],"values":[0.5]}}}"#)
        #expect(row.cell(for: "id") == "5c56c793-69f3-4fbf-87e6-c4bf54c28c26")
        #expect(row.cell(for: "vector.image") == "[0.5,1]")
        #expect(row.cell(for: "vector.keywords") == #"{"indices":[1],"values":[0.5]}"#)
        #expect(row.cell(for: "vector.text") == nil)
    }

    @Test("An unnamed vector beside sparse ones comes back under the empty name")
    func unnamedBesideSparse() throws {
        let row = try point(#"{"id":1,"vector":{"":[1,2],"sp":{"indices":[0],"values":[1]}}}"#)
        #expect(row.cell(for: "vector") == "[1,2]")
        #expect(QdrantPoint.columns(of: [row], collection: nil) == ["id", "vector", "vector.sp"])
    }

    @Test("A vector type name maps back to its kind")
    func vectorKinds() {
        #expect(QdrantVectorSpec.kind(ofTypeName: "vector(384)") == .dense(size: 384))
        #expect(QdrantVectorSpec.kind(ofTypeName: "VECTOR") == .dense(size: nil))
        #expect(QdrantVectorSpec.kind(ofTypeName: "multivector") == .multi)
        #expect(QdrantVectorSpec.kind(ofTypeName: "sparse_vector") == .sparse)
        #expect(QdrantVectorSpec.kind(ofTypeName: "keyword") == nil)
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
        #expect(QdrantPoint.list(fromResponse: ["result": [Any]()])?.isEmpty == true)
    }

    @Test("Point ids parse back to the kind Qdrant expects")
    func pointIDs() {
        #expect(QdrantPointID.json(from: "42") as? NSNumber == 42)
        #expect(QdrantPointID.json(from: "5C56C793-69F3-4FBF-87E6-C4BF54C28C26") as? String == "5c56c793-69f3-4fbf-87e6-c4bf54c28c26")
        #expect(QdrantPointID.json(from: "-1") == nil)
        #expect(QdrantPointID.json(from: "abc") == nil)
    }
}
