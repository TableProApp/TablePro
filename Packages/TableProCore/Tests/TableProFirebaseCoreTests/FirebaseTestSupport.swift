import Foundation
@testable import TableProFirebaseCore

final class FakeFirebaseTransport: FirebaseTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [FirebaseHTTPResponse] = []
    private var _requests: [FirebaseHTTPRequest] = []

    var requests: [FirebaseHTTPRequest] {
        lock.withLock { _requests }
    }

    func enqueue(status: Int = 200, json: String, headers: [String: String] = [:]) {
        lock.withLock { queued.append(FirebaseHTTPResponse(statusCode: status, headers: headers, body: Data(json.utf8))) }
    }

    func send(_ request: FirebaseHTTPRequest) async throws -> FirebaseHTTPResponse {
        try lock.withLock {
            _requests.append(request)
            guard !queued.isEmpty else {
                throw FirebaseError.malformedResponse("No fake response for \(request.method) \(request.url)")
            }
            return queued.removeFirst()
        }
    }

    func cancelAll() {}
}

final class CountingCredential: @unchecked Sendable {
    private let lock = NSLock()
    private var issued = 0
    private var invalidations = 0

    var invalidateCount: Int { lock.withLock { invalidations } }

    var credential: FirebaseCredential {
        FirebaseCredential(
            token: { [self] in lock.withLock { issued += 1; return "token-\(issued)" } },
            invalidate: { [self] in lock.withLock { invalidations += 1 } }
        )
    }
}

let testDocumentRoot = "projects/demo/databases/(default)/documents"

func makeFirestoreClient(_ transport: FakeFirebaseTransport, credential: FirebaseCredential = .emulator) -> FirestoreClient {
    FirestoreClient(
        projectId: "demo",
        database: "(default)",
        baseURL: URL(string: "https://firestore.googleapis.com/v1/") ?? URL(fileURLWithPath: "/"),
        transport: transport,
        credential: credential,
        timeout: { 30 }
    )
}

func makeDatabaseClient(_ transport: FakeFirebaseTransport, url: String = "https://demo-default-rtdb.europe-west1.firebasedatabase.app/") -> RealtimeDatabaseClient {
    RealtimeDatabaseClient(
        instanceURL: URL(string: url) ?? URL(fileURLWithPath: "/"),
        transport: transport,
        credential: .emulator,
        timeout: { 30 }
    )
}

func json(_ text: String) -> FirebaseJSON {
    (try? FirebaseJSON.parse(text)) ?? .null
}

func noTypes(_ column: String) -> String? { nil }
