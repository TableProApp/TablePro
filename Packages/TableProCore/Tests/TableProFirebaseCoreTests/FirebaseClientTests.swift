import Foundation
@testable import TableProFirebaseCore
import Testing

@Suite("Firestore client")
struct FirestoreClientTests {
    @Test("runQuery reads documents and skips the empty read-time entry")
    func runQuery() async throws {
        let transport = FakeFirebaseTransport()
        transport.enqueue(json: """
        [{"document": {"name": "projects/demo/databases/(default)/documents/users/alice",
                       "fields": {"age": {"integerValue": "30"}}, "updateTime": "2026-10-12T08:00:00Z"},
          "readTime": "2026-10-12T08:00:01Z"},
         {"readTime": "2026-10-12T08:00:01Z"}]
        """)
        let client = makeFirestoreClient(transport)
        let documents = try await client.runQuery(parent: "", body: json(#"{"structuredQuery": {}}"#), operation: "read users")
        #expect(documents == [FirestoreDocument(path: "users/alice", fields: ["age": .integer(30)], updateTime: "2026-10-12T08:00:00Z")])
        let request = try #require(transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://firestore.googleapis.com/v1/projects/demo/databases/(default)/documents:runQuery")
        #expect(request.headers["Authorization"] == "Bearer owner")
    }

    @Test("A denial names the operation and points at IAM and the rules")
    func permissionDenied() async throws {
        let transport = FakeFirebaseTransport()
        transport.enqueue(status: 403, json: #"{"error": {"code": 403, "message": "Missing or insufficient permissions.", "status": "PERMISSION_DENIED"}}"#)
        let client = makeFirestoreClient(transport)
        do {
            _ = try await client.runQuery(parent: "", body: .object([:]), operation: "read users")
            Issue.record("Expected a denial")
        } catch let error as FirebaseError {
            guard case .permissionDenied(let operation, let detail) = error else {
                Issue.record("Expected permissionDenied, got \(error)")
                return
            }
            #expect(operation == "read users")
            #expect(detail.contains("Missing or insufficient permissions."))
            #expect(error.localizedDescription.hasPrefix("Permission denied: read users."))
        }
    }

    @Test("A 401 drops the cached token and retries once")
    func retriesOnce() async throws {
        let transport = FakeFirebaseTransport()
        transport.enqueue(status: 401, json: #"{"error": {"message": "expired"}}"#)
        transport.enqueue(json: #"{"collectionIds": ["users", "orders"]}"#)
        let counter = CountingCredential()
        let client = makeFirestoreClient(transport, credential: counter.credential)
        #expect(try await client.listCollectionIds(parent: "") == ["users", "orders"])
        #expect(counter.invalidateCount == 1)
        #expect(transport.requests.map { $0.headers["Authorization"] } == ["Bearer token-1", "Bearer token-2"])
    }

    @Test("A missing document is nil, not an error")
    func missingDocument() async throws {
        let transport = FakeFirebaseTransport()
        transport.enqueue(status: 404, json: #"{"error": {"message": "not found"}}"#)
        #expect(try await makeFirestoreClient(transport).getDocument("users/ghost") == nil)
    }

    @Test("A patch sends the mask, the precondition and encoded path segments")
    func patch() async throws {
        let transport = FakeFirebaseTransport()
        transport.enqueue(json: "{}")
        try await makeFirestoreClient(transport).patchDocument(
            "users/a b", fields: ["first-name": .string("A")], mask: ["first-name"], updateTime: "2026-10-12T08:00:00Z"
        )
        let request = try #require(transport.requests.first)
        #expect(request.method == "PATCH")
        #expect(request.url.absoluteString == "https://firestore.googleapis.com/v1/projects/demo/databases/(default)/documents/users/a%20b?updateMask.fieldPaths=%60first-name%60&currentDocument.updateTime=2026-10-12T08:00:00Z")
        #expect(String(data: request.body ?? Data(), encoding: .utf8) == #"{"fields":{"first-name":{"stringValue":"A"}}}"#)
    }

    @Test("Firestore's FAILED_PRECONDITION is a precondition, other 400s are not")
    func failedPrecondition() {
        let stale = Data(#"{"error": {"code": 400, "message": "stored version mismatch", "status": "FAILED_PRECONDITION"}}"#.utf8)
        #expect(FirebaseError.from(status: 400, body: stale, operation: "write") == .precondition("stored version mismatch"))
        let invalid = Data(#"{"error": {"code": 400, "message": "bad field", "status": "INVALID_ARGUMENT"}}"#.utf8)
        #expect(FirebaseError.from(status: 400, body: invalid, operation: "write") == .api(status: 400, message: "bad field"))
    }

    @Test("Only native-mode databases are listed")
    func databases() async throws {
        let transport = FakeFirebaseTransport()
        transport.enqueue(json: """
        {"databases": [{"name": "projects/demo/databases/(default)", "type": "FIRESTORE_NATIVE"},
                       {"name": "projects/demo/databases/legacy", "type": "DATASTORE_MODE"},
                       {"name": "projects/demo/databases/eu", "type": "FIRESTORE_NATIVE"}]}
        """)
        #expect(try await makeFirestoreClient(transport).listDatabases() == ["(default)", "eu"])
    }

    @Test("The count comes from the aggregation result")
    func count() async throws {
        let transport = FakeFirebaseTransport()
        transport.enqueue(json: #"[{"result": {"aggregateFields": {"total": {"integerValue": "1234"}}}, "readTime": "x"}]"#)
        #expect(try await makeFirestoreClient(transport).count(parent: "", body: .object([:]), operation: "count") == 1_234)
    }
}

@Suite("Realtime Database client")
struct RealtimeDatabaseClientTests {
    @Test("URLs end in .json, encode segments and keep the emulator namespace")
    func urls() throws {
        let transport = FakeFirebaseTransport()
        let client = makeDatabaseClient(transport)
        #expect(try client.url("/chats/a b", query: [URLQueryItem(name: "orderBy", value: "\"$key\"")]).absoluteString
            == "https://demo-default-rtdb.europe-west1.firebasedatabase.app/chats/a%20b.json?orderBy=%22$key%22")
        #expect(try client.url("").absoluteString == "https://demo-default-rtdb.europe-west1.firebasedatabase.app/.json")
        let emulator = makeDatabaseClient(transport, url: "http://127.0.0.1:9000/?ns=demo-app")
        #expect(try emulator.url("x", query: [URLQueryItem(name: "shallow", value: "true")]).absoluteString
            == "http://127.0.0.1:9000/x.json?ns=demo-app&shallow=true")
        #expect(emulator.instanceName == "demo-app")
        #expect(client.instanceName == "demo-default-rtdb")
    }

    @Test("Children come back in the requested order with the offset dropped")
    func children() async throws {
        let transport = FakeFirebaseTransport()
        transport.enqueue(json: #"{"c": {"n": 3}, "a": {"n": 1}, "b": {"n": 2}}"#)
        let plan = try RealtimeDatabaseQueryPlanner.plan(spec: FirebaseBrowseSpec(table: "x", limit: 2, offset: 1), typeOf: noTypes)
        let children = try await makeDatabaseClient(transport).children("x", plan: plan)
        #expect(children.map(\.key) == ["b", "c"])
    }

    @Test("An array node is read as children keyed by index, without its holes")
    func arrays() async throws {
        let transport = FakeFirebaseTransport()
        transport.enqueue(json: #"[null, "one", "two"]"#)
        let plan = try RealtimeDatabaseQueryPlanner.plan(spec: FirebaseBrowseSpec(table: "x", limit: 0, offset: 0), typeOf: noTypes)
        let children = try await makeDatabaseClient(transport).children("x", plan: plan)
        #expect(children.map(\.key) == ["1", "2"])
    }

    @Test("An instance asked for in the wrong region moves to the URL the server names, if it is Firebase's")
    func regionRedirect() async throws {
        let transport = FakeFirebaseTransport()
        transport.enqueue(status: 404, json: #"{"correctUrl": "https://demo-default-rtdb.europe-west1.firebasedatabase.app", "error": "Database lives in a different region."}"#)
        transport.enqueue(json: "null")
        let client = makeDatabaseClient(transport, url: "https://demo-default-rtdb.firebaseio.com/")
        try await client.ping()
        #expect(client.currentURL.absoluteString == "https://demo-default-rtdb.europe-west1.firebasedatabase.app/")
        #expect(transport.requests[1].url.host == "demo-default-rtdb.europe-west1.firebasedatabase.app")

        let hostile = FakeFirebaseTransport()
        hostile.enqueue(status: 404, json: #"{"correctUrl": "https://evil.example.com", "error": "moved"}"#)
        let stays = makeDatabaseClient(hostile, url: "https://demo-default-rtdb.firebaseio.com/")
        await #expect(throws: FirebaseError.self) { try await stays.ping() }
        #expect(stays.currentURL.host == "demo-default-rtdb.firebaseio.com")
        #expect(hostile.requests.count == 1)
    }

    @Test("The instance list names a quota project only when the API asks for one")
    func quotaProjectRetry() async throws {
        let transport = FakeFirebaseTransport()
        transport.enqueue(status: 403, json: #"{"error": {"message": "The firebasedatabase.googleapis.com API requires a quota project, which is not set by default."}}"#)
        transport.enqueue(json: #"{"instances": [{"databaseUrl": "https://b.europe-west1.firebasedatabase.app", "state": "ACTIVE"}, {"databaseUrl": "https://a.firebaseio.com", "state": "ACTIVE"}, {"databaseUrl": "https://c.firebaseio.com", "state": "DISABLED"}]}"#)
        let lister = RealtimeDatabaseInstanceLister(transport: transport, credential: .emulator, timeout: { 30 })
        let urls = try await lister.instances(projectId: "demo")
        #expect(urls.map(\.absoluteString) == ["https://a.firebaseio.com/", "https://b.europe-west1.firebasedatabase.app/"])
        #expect(transport.requests[0].headers["x-goog-user-project"] == nil)
        #expect(transport.requests[1].headers["x-goog-user-project"] == "demo")
    }

    @Test("A rules denial is a permission error, not an empty node")
    func denied() async {
        let transport = FakeFirebaseTransport()
        transport.enqueue(status: 401, json: #"{"error": "Permission denied"}"#)
        transport.enqueue(status: 403, json: #"{"error": "Permission denied"}"#)
        do {
            _ = try await makeDatabaseClient(transport).get("secrets")
            Issue.record("Expected a denial")
        } catch let error as FirebaseError {
            #expect(error == .permissionDenied(
                operation: "read /secrets",
                detail: "The credential lacks the IAM role for this, or the security rules block it."
            ))
        } catch {
            Issue.record("Unexpected \(error)")
        }
    }

    @Test("A guarded write sends if-match and reports a moved ETag as a precondition")
    func guardedWrite() async throws {
        let transport = FakeFirebaseTransport()
        transport.enqueue(json: #"{"a": 1}"#, headers: ["ETag": "abc"])
        transport.enqueue(status: 412, json: #"{"error": "ETag mismatch"}"#)
        let client = makeDatabaseClient(transport)
        let read = try await client.getWithETag("node")
        #expect(read.etag == "abc")
        await #expect(throws: FirebaseError.precondition("ETag mismatch")) {
            try await client.put("node", value: .object(["a": .int(2)]), ifMatch: "abc")
        }
        #expect(transport.requests[0].headers["X-Firebase-ETag"] == "true")
        #expect(transport.requests[1].headers["if-match"] == "abc")
        #expect(transport.requests[1].url.query == nil)
    }
}
