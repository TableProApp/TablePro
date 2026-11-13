//
//  QueryClassifierOneItemDeleteTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProSQLGrammar
import TableProWeaviateCore
import Testing

struct QueryClassifierOneItemDeleteTests {
    @Test("A delete of one item by its id or key is a write", arguments: [
        (DatabaseType.elasticsearch, "DELETE /orders/_doc/1"),
        (.elasticsearch, "DELETE orders/_doc/1?refresh=true&routing=a"),
        (.elasticsearch, "DELETE /orders/_doc/1\n{}"),
        (.typesense, "DELETE /collections/books/documents/1"),
        (.typesense, "DELETE /collections/books/documents/1?ignore_not_found=true"),
        (.qdrant, #"POST /collections/docs/points/delete\#n{"points": [1]}"#),
        (.qdrant, #"POST /collections/docs/points/delete?wait=true {"points": ["5c56c793-69f3-4fbf-87e6-c4bf54c28c26"]}"#),
        (.qdrant, #"POST /collections/docs/points/delete\#n{"points": [7], "shard_key": "eu"}"#),
        (.weaviate, "DELETE /v1/objects/Article/36ddd591-2dee-4e7e-a3cc-eb86d30a4303"),
        (.weaviate, "DELETE /objects/Article/36ddd591-2dee-4e7e-a3cc-eb86d30a4303?tenant=t1"),
        (.weaviate, #"DELETE /v1/objects/Article/36ddd591-2dee-4e7e-a3cc-eb86d30a4303/references/author\#n{"beacon": "weaviate://localhost/Author/1"}"#),
        (.weaviate, "DELETE /v1/objects/36ddd591-2dee-4e7e-a3cc-eb86d30a4303/references/author"),
        (.firestore, "DELETE users/alice"),
        (.firestore, "DELETE users/alice/orders/1"),
        (.firebaseRealtimeDatabase, "DELETE users/alice"),
        (.firebaseRealtimeDatabase, "DELETE /users/alice/age"),
        (.firebaseRealtimeDatabase, "PUT users/alice null"),
        (.firebaseRealtimeDatabase, #"PUT users/alice {".priority": 1}"#),
        (.firebaseRealtimeDatabase, #"PATCH users {"alice": null}"#),
        (.firebaseRealtimeDatabase, #"PATCH / {"users/alice": null, "users/bob/age": 3}"#),
        (.firebaseRealtimeDatabase, #"PATCH users/alice {"age": null}"#),
        (.bigtable, "DELETE events/user#42"),
        (.bigtable, "DELETE events/user#42 profile:name"),
        (.bigtable, #"PUT events/user#42 {"profile:name": null}"#),
        (.bigtable, #"PUT events/"a{b" {"cf:a": null}"#),
    ])
    func oneItemDeleteIsAWrite(type: DatabaseType, request: String) {
        #expect(QueryClassifier.classifyTier(request, databaseType: type) == .write)
        #expect(!QueryClassifier.isDangerousQuery(request, databaseType: type))
    }

    @Test("A delete of a container, every item, a batch, a filter or a range stays destructive", arguments: [
        (DatabaseType.elasticsearch, "DELETE /orders"),
        (.elasticsearch, "DELETE /orders/_doc"),
        (.elasticsearch, "DELETE /orders/_doc/"),
        (.elasticsearch, "DELETE /orders/_doc/1/extra"),
        (.elasticsearch, "DELETE /orders/_doc/_query"),
        (.elasticsearch, "DELETE /_all/_doc/1"),
        (.elasticsearch, "DELETE /a,b/_doc/1"),
        (.elasticsearch, "DELETE /orders*/_doc/1"),
        (.elasticsearch, "DELETE /remote:orders/_doc/1"),
        (.elasticsearch, "DELETE /-orders/_doc/1"),
        (.elasticsearch, "DELETE /.security-7/_doc/1"),
        (.elasticsearch, "DELETE /%3Clogs-%7Bnow%7D%3E/_doc/1"),
        (.elasticsearch, "DELETE /orders/_doc/../_doc/1"),
        (.elasticsearch, "DELETE //orders/_doc/1"),
        (.typesense, "DELETE /collections/books"),
        (.typesense, "DELETE /collections/books/documents?filter_by=x:1"),
        (.typesense, "DELETE /collections/books/documents/1/../"),
        (.typesense, "DELETE /aliases/a"),
        (.typesense, "DELETE /keys/1"),
        (.qdrant, #"POST /collections/docs/points/delete\#n{"points": [1, 2]}"#),
        (.qdrant, #"POST /collections/docs/points/delete\#n{"filter": {"must": [{"key": "city", "match": {"value": "x"}}]}}"#),
        (.qdrant, #"POST /collections/docs/points/delete\#n{"points": [1], "filter": {}}"#),
        (.qdrant, #"POST /collections/docs/points/delete\#n{"points": [[1]]}"#),
        (.qdrant, "POST /collections/docs/points/delete"),
        (.qdrant, #"POST /collections/docs/points/payload/delete\#n{"keys": ["a"], "points": [1]}"#),
        (.qdrant, #"POST /collections/docs/points/vectors/delete\#n{"vector": ["v"], "points": [1]}"#),
        (.qdrant, #"POST /collections/docs/points/batch\#n{"operations": [{"delete": {"points": [1]}}]}"#),
        (.qdrant, "DELETE /collections/docs"),
        (.weaviate, "DELETE /v1/batch/objects"),
        (.weaviate, "DELETE /v1/schema/Article"),
        (.weaviate, "DELETE /v1/schema/Article/tenants"),
        (.weaviate, "DELETE /v1/objects/36ddd591-2dee-4e7e-a3cc-eb86d30a4303"),
        (.weaviate, "DELETE /v1/objects/Article/../36ddd591-2dee-4e7e-a3cc-eb86d30a4303"),
        (.firestore, "DELETE users"),
        (.firestore, "DELETE /"),
        (.firestore, "DELETE ./alice"),
        (.firebaseRealtimeDatabase, "DELETE users"),
        (.firebaseRealtimeDatabase, "DELETE /"),
        (.firebaseRealtimeDatabase, "PUT users null"),
        (.firebaseRealtimeDatabase, #"PATCH / {"users": null}"#),
        (.firebaseRealtimeDatabase, #"PATCH / {"users": {"alice": null}}"#),
        (.firebaseRealtimeDatabase, #"PATCH / {"users/alice": null, "orders": null}"#),
        (.firebaseRealtimeDatabase, #"PATCH users {"": null}"#),
        (.firebaseRealtimeDatabase, "DELETE .settings/rules"),
    ])
    func manyItemDeleteStaysDestructive(type: DatabaseType, request: String) {
        #expect(QueryClassifier.classifyTier(request, databaseType: type) == .destructive)
        #expect(QueryClassifier.isDangerousQuery(request, databaseType: type))
    }

    // The server deletes a class-less `/v1/objects/<id>` in every class, so only the class route is one object.
    @Test("A grid delete of a Weaviate object is tiered by the path it sends", arguments: [
        ("/v1/objects/Article/36ddd591-2dee-4e7e-a3cc-eb86d30a4303", QueryTier.write),
        ("/v1/objects/36ddd591-2dee-4e7e-a3cc-eb86d30a4303", .destructive),
        ("/v1/batch/objects", .destructive),
    ])
    func weaviateTaggedDeleteFollowsItsPath(path: String, tier: QueryTier) {
        let write = WeaviateWriteRequest(method: "DELETE", path: path, query: ["class": "Article"], body: nil)
        #expect(QueryClassifier.weaviateClassification(WeaviateWriteCodec.encode(write)).tier == tier)
    }

    @Test("Firestore PUT and PATCH keep their tiers")
    func firestorePutAndPatchUnchanged() {
        #expect(QueryClassifier.classifyTier("PUT users/alice null", databaseType: .firestore) == .destructive)
        #expect(QueryClassifier.classifyTier(#"PATCH users/alice {"age": null}"#, databaseType: .firestore) == .write)
    }
}
