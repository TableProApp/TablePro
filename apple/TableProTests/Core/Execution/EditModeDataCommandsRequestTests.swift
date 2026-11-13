//
//  EditModeDataCommandsRequestTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct EditModeDataCommandsRequestTests {
    private func statement(_ sql: String, databaseType: DatabaseType) -> ExternalStatementGate.Statement {
        ExternalStatementGate.Statement(
            sql: sql,
            connectionId: UUID(),
            databaseType: databaseType,
            externalAccess: .readWrite,
            loadsExtensions: false,
            allowsDestructive: false,
            allowsOnlyDataStatements: true
        )
    }

    private func refusal(_ sql: String, on databaseType: DatabaseType) -> ExternalStatementGateError? {
        do {
            try ExternalStatementGate.classify(statement(sql, databaseType: databaseType))
            return nil
        } catch let error as ExternalStatementGateError {
            return error
        } catch {
            return nil
        }
    }

    @Test("Edit refuses an Elasticsearch request that is not a read or a document change", arguments: [
        "PUT /orders2",
        #"PUT /orders/_mapping\#n{"properties": {"note": {"type": "keyword"}}}"#,
        #"POST /_aliases\#n{"actions": [{"add": {"index": "orders", "alias": "o"}}]}"#,
        #"PUT /_security/user/bob\#n{"password": "secret123", "roles": ["superuser"]}"#,
        #"POST /_security/api_key\#n{"name": "k"}"#,
        #"PUT /_cluster/settings\#n{"persistent": {"action.destructive_requires_name": false}}"#,
        #"PUT /_ilm/policy/purge\#n{"policy": {"phases": {"delete": {"min_age": "0ms", "actions": {"delete": {}}}}}}"#,
        "GET /_flush",
        #"PUT /_ingest/pipeline/p\#n{"processors": [{"set": {"field": "x", "value": 1}}]}"#,
        #"PUT /_watcher/watch/w\#n{"trigger": {"schedule": {"interval": "1m"}}, "actions": {}}"#,
        #"PUT /_inference/text_embedding/e\#n{"service": "openai", "service_settings": {"api_key": "k", "model_id": "m"}}"#,
        "POST /_update_by_query/abc:1/_rethrottle?requests_per_second=-1",
        #"POST /_reindex\#n{"source": {"index": "orders"}, "dest": {"index": "orders2"}}"#,
        #"PUT /.watches/_doc/w1\#n{"trigger": {}}"#,
        #"POST /_bulk\#n{"index": {"_index": ".security-7", "_id": "x"}}\#n{"a": 1}"#,
        #"POST /orders*/_update_by_query?expand_wildcards=all\#n{"query": {"match_all": {}}}"#,
        "PUT /orders/_doc/../../_cluster/settings\n{}",
        #"POST /_query/async\#n{"query": "FROM orders", "keep_on_completion": true}"#,
    ])
    func elasticsearchRefusesTheRest(sql: String) {
        #expect(refusal(sql, on: .elasticsearch) == .denied(ExternalStatementGate.dataStatementRefusal))
    }

    @Test("Edit runs Elasticsearch reads and document changes", arguments: [
        #"PUT /orders/_doc/1\#n{"total": 5}"#,
        #"POST /orders/_doc\#n{"total": 5}"#,
        #"PUT /orders/_create/2\#n{"total": 7}"#,
        #"POST /orders/_update/1\#n{"doc": {"total": 6}}"#,
        #"POST /orders/_update_by_query\#n{"query": {"term": {"status": "new"}}, "script": {"source": "ctx._source.status = 'old'"}}"#,
        #"POST /_bulk\#n{"index": {"_index": "orders", "_id": "3"}}\#n{"total": 1}"#,
        #"GET /orders/_update_by_query\#n{"query": {"match_all": {}}, "script": {"source": "ctx._source.n = 1"}}"#,
        "GET /orders/_search",
        #"POST /_query\#n{"query": "FROM orders | LIMIT 5"}"#,
        #"POST /orders/_mget\#n{"ids": ["1", "2"]}"#,
        #"GET /_all/_search\#n{"query": {"match_all": {}}}"#,
    ])
    func elasticsearchRunsDataRequests(sql: String) {
        #expect(refusal(sql, on: .elasticsearch) == nil)
    }

    @Test("Edit refuses a Typesense request that is not a read or a document change", arguments: [
        #"POST /collections\#n{"name": "c", "fields": [{"name": "t", "type": "string"}]}"#,
        #"PATCH /collections/books\#n{"fields": [{"name": "title", "drop": true}]}"#,
        #"PUT /aliases/a\#n{"collection_name": "books"}"#,
        #"PUT /collections/books/synonyms/s\#n{"synonyms": ["a", "b"]}"#,
        #"POST /config\#n{"log-slow-requests-time-ms": 1}"#,
        "POST /operations/cache/clear",
        #"POST /conversations/models\#n{"model_name": "openai/gpt-4o", "api_key": "k", "history_collection": "h"}"#,
        #"POST /proxy\#n{"url": "http://169.254.169.254/", "method": "GET"}"#,
        #"POST /analytics/events\#n{"type": "click", "name": "e", "data": {}}"#,
        "POST /collections/books/documents/../../../config\n{}",
    ])
    func typesenseRefusesTheRest(sql: String) {
        #expect(refusal(sql, on: .typesense) == .denied(ExternalStatementGate.dataStatementRefusal))
    }

    @Test("Edit runs Typesense reads and document changes", arguments: [
        #"POST /collections/books/documents\#n{"id": "1", "title": "x"}"#,
        #"POST /collections/books/documents?action=upsert\#n{"id": "1", "title": "y"}"#,
        #"POST /collections/books/documents/import?action=upsert\#n{"id": "1", "title": "a"}\#n{"id": "2", "title": "b"}"#,
        #"PATCH /collections/books/documents/1\#n{"title": "z"}"#,
        #"PATCH /collections/books/documents?filter_by=year:<2000\#n{"old": true}"#,
        "GET /collections/books/documents/search?q=*&query_by=title",
        #"POST /multi_search\#n{"searches": [{"collection": "books", "q": "*"}]}"#,
    ])
    func typesenseRunsDataRequests(sql: String) {
        #expect(refusal(sql, on: .typesense) == nil)
    }

    @Test("Edit refuses a Qdrant request that is not a read or a point change", arguments: [
        #"PUT /collections/docs\#n{"vectors": {"size": 4, "distance": "Cosine"}}"#,
        #"PATCH /collections/docs\#n{"optimizers_config": {"indexing_threshold": 0}}"#,
        #"PUT /collections/docs/index\#n{"field_name": "city", "field_schema": "keyword"}"#,
        #"PUT /collections/docs/vectors/v2\#n{"size": 4, "distance": "Dot"}"#,
        #"PUT /collections/docs/shards\#n{"shard_key": "k"}"#,
        "PUT /quotas\n{}",
        #"POST /locks\#n{"write": true, "error_message": "x"}"#,
    ])
    func qdrantRefusesTheRest(sql: String) {
        #expect(refusal(sql, on: .qdrant) == .denied(ExternalStatementGate.dataStatementRefusal))
    }

    @Test("Edit runs Qdrant reads and point changes", arguments: [
        #"PUT /collections/docs/points?wait=true\#n{"points": [{"id": 1, "vector": [0.1, 0.2, 0.3, 0.4], "payload": {"city": "Hanoi"}}]}"#,
        #"POST /collections/docs/points/payload\#n{"payload": {"a": 1}, "points": [1]}"#,
        #"PUT /collections/docs/points/vectors\#n{"points": [{"id": 1, "vector": [0.4, 0.3, 0.2, 0.1]}]}"#,
        #"POST /collections/docs/points/query\#n{"query": [0.1, 0.2, 0.3, 0.4], "limit": 3}"#,
        "GET /collections/docs",
    ])
    func qdrantRunsDataRequests(sql: String) {
        #expect(refusal(sql, on: .qdrant) == nil)
    }

    @Test("Edit refuses a Weaviate request that is not a read or an object change", arguments: [
        #"POST /v1/schema\#n{"class": "Article"}"#,
        #"POST /v1/schema/Article/properties\#n{"name": "x", "dataType": ["text"]}"#,
        #"POST /v1/schema/Article/tenants\#n[{"name": "t1"}]"#,
        "POST /v1/users/db/bob",
        #"POST /v1/authz/users/bob/assign\#n{"roles": ["admin"]}"#,
        #"POST /v1/backups/filesystem\#n{"id": "b1"}"#,
        #"POST /v1/mcp\#n{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}"#,
        #"POST /v1/classifications/\#n{"class": "Article", "classifyProperties": ["cat"], "basedOnProperties": ["title"], "type": "knn"}"#,
        #"PUT /v1/objects/../schema/Article\#n{"class": "Article"}"#,
    ])
    func weaviateRefusesTheRest(sql: String) {
        #expect(refusal(sql, on: .weaviate) == .denied(ExternalStatementGate.dataStatementRefusal))
    }

    @Test("Edit runs Weaviate reads and object changes", arguments: [
        #"POST /v1/objects\#n{"class": "Article", "properties": {"title": "x"}}"#,
        #"PATCH /v1/objects/Article/36ddd591-2dee-4e7e-a3cc-eb86d30a4303\#n{"properties": {"title": "y"}}"#,
        #"POST /v1/batch/objects\#n{"objects": [{"class": "Article", "properties": {"title": "a"}}]}"#,
        #"POST /v1/batch/references\#n[{"from": "weaviate://localhost/Article/1/author", "to": "weaviate://localhost/Author/2"}]"#,
        "{ Get { Article { title } } }",
        #"POST /v1/graphql\#n{"query": "{ Get { Article { title } } }"}"#,
        "GET /v1/objects?class=Article&limit=10",
    ])
    func weaviateRunsDataRequests(sql: String) {
        #expect(refusal(sql, on: .weaviate) == nil)
    }

    @Test("Edit refuses a Realtime Database write into the server's own nodes", arguments: [
        #"PUT .settings/defaultWriteSizeLimit "unlimited""#,
        "PUT .settings/strictTriggerValidation false",
        #"PATCH / {".settings/defaultWriteSizeLimit": "unlimited"}"#,
    ])
    func realtimeDatabaseRefusesServerNodes(sql: String) {
        #expect(refusal(sql, on: .firebaseRealtimeDatabase) == .denied(ExternalStatementGate.dataStatementRefusal))
    }

    @Test("Edit runs Realtime Database reads and node changes", arguments: [
        #"PUT users/alice {"age": 31}"#,
        #"PATCH users/alice {"age": 32}"#,
        #"PATCH / {"users/alice/age": 33}"#,
        #"POST logs {"msg": "hi"}"#,
        #"GET users?orderBy="$key"&limitToFirst=5"#,
    ])
    func realtimeDatabaseRunsDataRequests(sql: String) {
        #expect(refusal(sql, on: .firebaseRealtimeDatabase) == nil)
    }

    @Test("Edit refuses a Firestore write through a dot segment, and the PUT Firestore lacks", arguments: [
        #"PATCH ./../x/y {"a": 1}"#,
        #"POST ./../x {"a": 1}"#,
        #"PUT users/alice {"age": 31}"#,
    ])
    func firestoreRefusesTheRest(sql: String) {
        #expect(refusal(sql, on: .firestore) == .denied(ExternalStatementGate.dataStatementRefusal))
    }

    @Test("Edit runs Firestore reads and document changes", arguments: [
        #"POST users?documentId=alice {"age": 31}"#,
        #"PATCH users/alice?updateMask=age {"age": 32}"#,
        #"QUERY {"structuredQuery": {"from": [{"collectionId": "users"}]}}"#,
        "GET users/alice",
    ])
    func firestoreRunsDataRequests(sql: String) {
        #expect(refusal(sql, on: .firestore) == nil)
    }

    @Test("Edit refuses a Bigtable request the driver cannot read", arguments: ["CREATE events", "DROP events"])
    func bigtableRefusesTheRest(sql: String) {
        #expect(refusal(sql, on: .bigtable) == .denied(ExternalStatementGate.dataStatementRefusal))
    }

    @Test("Edit runs Bigtable reads and row changes", arguments: [
        #"INSERT events/user#42 {"profile:name": "Ann"}"#,
        #"PUT events/user#42 {"profile:name": "Bo"}"#,
        "GET events/user#42",
        "SCAN events/user#?limit=20",
        #"READ events {"rowsLimit": "10"}"#,
    ])
    func bigtableRunsDataRequests(sql: String) {
        #expect(refusal(sql, on: .bigtable) == nil)
    }

    @Test("Edit runs a delete of one item by its id or key, which is a write", arguments: [
        (DatabaseType.elasticsearch, "DELETE /orders/_doc/1"),
        (.typesense, "DELETE /collections/books/documents/1"),
        (.qdrant, #"POST /collections/docs/points/delete\#n{"points": [1]}"#),
        (.weaviate, "DELETE /v1/objects/Article/36ddd591-2dee-4e7e-a3cc-eb86d30a4303"),
        (.firestore, "DELETE users/alice"),
        (.firebaseRealtimeDatabase, "DELETE users/alice"),
        (.bigtable, "DELETE events/user#42"),
    ])
    func oneItemDeleteRunsInEdit(type: DatabaseType, sql: String) {
        #expect(QueryClassifier.isDataStatement(sql, databaseType: type))
        #expect(refusal(sql, on: type) == nil)
    }

    @Test("Edit refuses a delete of a container, a batch, a filter or every item as destructive", arguments: [
        (DatabaseType.elasticsearch, "DELETE /orders"),
        (.elasticsearch, "DELETE /orders,archive/_doc/1"),
        (.elasticsearch, #"POST /orders/_delete_by_query\#n{"query": {"match_all": {}}}"#),
        (.typesense, "DELETE /collections/books/documents?filter_by=year:<2000"),
        (.qdrant, #"POST /collections/docs/points/delete\#n{"points": [1, 2]}"#),
        (.qdrant, #"POST /collections/docs/points/delete\#n{"filter": {"must": [{"key": "city", "match": {"value": "x"}}]}}"#),
        (.weaviate, "DELETE /v1/objects/36ddd591-2dee-4e7e-a3cc-eb86d30a4303"),
        (.weaviate, #"DELETE /v1/batch/objects\#n{"match": {"class": "Article", "where": {"operator": "Like", "path": ["id"], "valueText": "*"}}}"#),
        (.firestore, "DELETE users"),
        (.firebaseRealtimeDatabase, "DELETE users"),
        (.firebaseRealtimeDatabase, #"PATCH / {"users": null}"#),
        (.firebaseRealtimeDatabase, #"PUT users {"x": {"name": "a"}}"#),
        (.firebaseRealtimeDatabase, #"PATCH / {"users": {"x": 1}}"#),
    ])
    func manyItemDeleteIsRefusedInEdit(type: DatabaseType, sql: String) {
        #expect(refusal(sql, on: type) == .denied(ExternalStatementGate.destructiveRefusal))
    }

    @Test("A write into the engine's own containers is not data, even where another rule refuses it first", arguments: [
        (DatabaseType.firebaseRealtimeDatabase, #"PUT .settings/rules {"rules": {".read": true, ".write": true}}"#),
        (.firebaseRealtimeDatabase, #"PUT %2Esettings/rules {"rules": {".read": true}}"#),
        (.firestore, "DELETE ./../collectionGroups/users/indexes/abc"),
        (.elasticsearch, "DELETE /.security-7/_doc/x"),
    ])
    func systemWriteIsNotData(type: DatabaseType, sql: String) {
        #expect(!QueryClassifier.isDataStatement(sql, databaseType: type))
        #expect(refusal(sql, on: type) != nil)
    }
}
