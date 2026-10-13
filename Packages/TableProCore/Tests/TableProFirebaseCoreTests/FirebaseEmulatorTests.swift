import Foundation
@testable import TableProFirebaseCore
import Testing

/// Runs against the Firebase emulators when their standard variables are set, for example
/// `FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 FIREBASE_DATABASE_EMULATOR_HOST=127.0.0.1:9000`.
enum FirebaseEmulatorEnvironment {
    static let firestoreHost = ProcessInfo.processInfo.environment["FIRESTORE_EMULATOR_HOST"]
    static let databaseHost = ProcessInfo.processInfo.environment["FIREBASE_DATABASE_EMULATOR_HOST"]
    static let project = "demo-tablepro"

    static func transport() -> URLSessionFirebaseTransport {
        URLSessionFirebaseTransport(resourceTimeout: 30)
    }
}

@Suite("Firestore emulator", .enabled(if: FirebaseEmulatorEnvironment.firestoreHost != nil), .serialized)
struct FirestoreEmulatorTests {
    private func client() throws -> FirestoreClient {
        let host = try #require(FirebaseEmulatorEnvironment.firestoreHost)
        return FirestoreClient(
            projectId: FirebaseEmulatorEnvironment.project,
            database: "(default)",
            baseURL: try #require(URL(string: "http://\(host)/v1/")),
            transport: FirebaseEmulatorEnvironment.transport(),
            credential: .emulator,
            timeout: { 10 }
        )
    }

    @Test("Create, query, count, patch with a stale time, and delete")
    func lifecycle() async throws {
        let client = try client()
        let collection = "tp_\(UUID().uuidString.prefix(8))"
        let created = try await client.createDocument(collectionPath: collection, documentId: "alice", fields: [
            "age": .integer(30), "when": .timestamp("2026-10-12T08:00:00Z"), "tags": .array([.string("vip")])
        ])
        _ = try await client.createDocument(collectionPath: collection, documentId: nil, fields: ["age": .integer(20)])
        #expect(created.path == "\(collection)/alice")

        let target = try FirestoreCollectionTarget(table: collection)
        let spec = FirebaseBrowseSpec(table: collection, filters: [FirebaseFilterSpec(column: "age", op: ">=", value: "25")], limit: 10, offset: 0)
        let types: (String) -> String? = { $0 == "age" ? "integer" : nil }
        let query = try FirestoreQueryBuilder.structuredQuery(spec: spec, target: target, documentRoot: client.documentRoot, typeOf: types)
        let documents = try await client.runQuery(parent: "", body: query, operation: "read")
        #expect(documents.map(\.path) == ["\(collection)/alice"])
        let all = FirebaseBrowseSpec(table: collection, limit: 0, offset: 0)
        let counted = try await client.count(
            parent: "", body: try FirestoreQueryBuilder.countQuery(spec: all, target: target, documentRoot: client.documentRoot, typeOf: types), operation: "count"
        )
        #expect(counted == 2)

        let stale = "2000-01-01T00:00:00Z"
        await expectPrecondition {
            try await client.patchDocument("\(collection)/alice", fields: ["age": .integer(31)], mask: ["age"], updateTime: stale)
        }
        try await client.patchDocument("\(collection)/alice", fields: ["age": .integer(31)], mask: ["age", "tags"])
        let patched = try #require(try await client.getDocument("\(collection)/alice"))
        #expect(patched.fields["age"] == .integer(31))
        #expect(patched.fields["tags"] == nil)
        #expect(patched.fields["when"] == .timestamp("2026-10-12T08:00:00Z"))

        #expect(try await client.listCollectionIds(parent: "").contains(collection))
        try await client.deleteDocument("\(collection)/alice")
        #expect(try await client.getDocument("\(collection)/alice") == nil)
    }
}

@Suite("Realtime Database emulator", .enabled(if: FirebaseEmulatorEnvironment.databaseHost != nil), .serialized)
struct RealtimeDatabaseEmulatorTests {
    private func client() throws -> RealtimeDatabaseClient {
        let host = try #require(FirebaseEmulatorEnvironment.databaseHost)
        return RealtimeDatabaseClient(
            instanceURL: try #require(URL(string: "http://\(host)/?ns=\(FirebaseEmulatorEnvironment.project)")),
            transport: FirebaseEmulatorEnvironment.transport(),
            credential: .emulator,
            timeout: { 10 }
        )
    }

    @Test("Write, read in order, guard with an ETag, and delete")
    func lifecycle() async throws {
        let client = try client()
        let node = "tp_\(UUID().uuidString.prefix(8))"
        try await client.put(node, value: json(#"{"b": {"n": 2}, "a": {"n": 3}, "c": {"n": 1}}"#))
        let pushed = try await client.push(node, value: json(#"{"n": 0}"#))
        #expect(pushed != nil)

        let byField = FirebaseBrowseSpec(table: node, sorts: [FirebaseSortSpec(column: "n", ascending: true)], limit: 2, offset: 1)
        let plan = try RealtimeDatabaseQueryPlanner.plan(spec: byField, typeOf: noTypes)
        do {
            _ = try await client.children(node, plan: plan)
            Issue.record("Expected the missing index to be reported")
        } catch let error as FirebaseError {
            #expect(error.localizedDescription.contains(".indexOn"))
        }
        try await client.put(".settings/rules", value: json(#"{"rules": {".read": "auth != null", ".write": "auth != null", "\#(node)": {".indexOn": ["n"]}}}"#))
        #expect(try await client.children(node, plan: plan).map(\.key) == ["c", "b"])
        #expect(try await client.childKeys(node).count == 4)

        let read = try await client.getWithETag("\(node)/a")
        let etag = try #require(read.etag)
        try await client.patch("\(node)/a", values: ["n": .int(30)])
        await expectPrecondition {
            try await client.put("\(node)/a", value: json(#"{"n": 99}"#), ifMatch: etag)
        }
        #expect(try await client.get("\(node)/a") == json(#"{"n": 30}"#))

        try await client.delete(node)
        #expect(try await client.get(node) == .null)
    }
}

/// A stale write has to fail as a precondition: any other error would mean the guard never ran.
private func expectPrecondition(_ body: () async throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
        try await body()
        Issue.record("Expected a precondition failure", sourceLocation: sourceLocation)
    } catch FirebaseError.precondition {
    } catch {
        Issue.record("Expected a precondition failure, got \(error)", sourceLocation: sourceLocation)
    }
}
