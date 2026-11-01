import Foundation
@testable import TableProQdrantCore

final class RecordingTransport: QdrantTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (QdrantHTTPRequest) throws -> QdrantHTTPResponse
    private(set) var requests: [QdrantHTTPRequest] = []

    init(_ handler: @escaping (QdrantHTTPRequest) throws -> QdrantHTTPResponse) {
        self.handler = handler
    }

    func send(_ request: QdrantHTTPRequest) async throws -> QdrantHTTPResponse {
        let handler = lock.withLock {
            requests.append(request)
            return self.handler
        }
        return try handler(request)
    }

    func cancelAll() {}

    var recorded: [QdrantHTTPRequest] { lock.withLock { requests } }
}

func jsonResponse(_ object: Any, status: Int = 200) -> QdrantHTTPResponse {
    QdrantHTTPResponse(statusCode: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
}

func bodyObject(_ request: QdrantHTTPRequest) -> [String: Any] {
    guard let body = request.body else { return [:] }
    return (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
}

func makeClient(apiKey: String = "", transport: RecordingTransport) -> QdrantClient {
    QdrantClient(
        settings: QdrantConnectionSettings(host: "localhost", port: 6_333, usesTLS: false, apiKey: apiKey, skipTLSVerify: false),
        transport: transport,
        timeout: { 5 }
    )
}

/// A collection of integer ids 1...count answering `scroll` the way Qdrant does: from `offset`
/// (an id) up to `limit` points, with the next id as the cursor.
func scrollingTransport(count: Int) -> RecordingTransport {
    RecordingTransport { request in
        let body = bodyObject(request)
        let limit = body["limit"] as? Int ?? 10
        let start = (body["offset"] as? Int) ?? 1
        let ids = Array(start..<min(start + limit, count + 1))
        let next: Any = start + limit <= count ? start + limit : NSNull()
        let points = ids.map { ["id": $0, "payload": ["n": $0]] as [String: Any] }
        return jsonResponse(["result": ["points": points, "next_page_offset": next], "status": "ok"])
    }
}

let sampleCollection = QdrantCollection(
    name: "docs",
    vectors: [QdrantVectorSpec(name: nil)],
    payloadFields: [
        QdrantPayloadField(name: "city", type: .keyword, isIndexed: true),
        QdrantPayloadField(name: "body", type: .text, isIndexed: true),
        QdrantPayloadField(name: "pop", type: .float, isIndexed: true),
        QdrantPayloadField(name: "count", type: .integer, isIndexed: false),
        QdrantPayloadField(name: "active", type: .bool, isIndexed: false),
        QdrantPayloadField(name: "note", type: .string, isIndexed: false),
        QdrantPayloadField(name: "tags", type: .array, isIndexed: false)
    ]
)

func canonical(_ object: Any) -> String {
    (try? QdrantJSON.text(object)) ?? ""
}
