import Foundation
@testable import TableProQdrantCore

final class RecordingTransport: QdrantTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: (QdrantHTTPRequest) throws -> QdrantHTTPResponse
    private var requests: [QdrantHTTPRequest] = []

    init(_ handler: @escaping (QdrantHTTPRequest) throws -> QdrantHTTPResponse) {
        self.handler = handler
    }

    func send(_ request: QdrantHTTPRequest) async throws -> QdrantHTTPResponse {
        lock.withLock { requests.append(request) }
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
        settings: QdrantConnectionSettings(host: "localhost", port: 6_333, usesTLS: false, apiKey: apiKey),
        transport: transport,
        timeout: { 5 }
    )
}

func scrollResponse(_ ids: [Int], next: Int?) -> QdrantHTTPResponse {
    let points = ids.map { ["id": $0, "payload": ["n": $0]] as [String: Any] }
    return jsonResponse(["result": ["points": points, "next_page_offset": next.map { $0 as Any } ?? NSNull()], "status": "ok"])
}

// Integer ids 1...count, answering `scroll` from `offset` (an id) the way Qdrant does.
func scrollingTransport(count: Int) -> RecordingTransport {
    RecordingTransport { request in
        let body = bodyObject(request)
        let limit = body["limit"] as? Int ?? 10
        let start = body["offset"] as? Int ?? 1
        let ids = Array(start..<min(start + limit, count + 1))
        return scrollResponse(ids, next: start + limit <= count ? start + limit : nil)
    }
}

let sampleCollection = QdrantCollection(
    name: "docs",
    vectors: [QdrantVectorSpec(name: "", kind: .dense(size: 2))],
    payloadFields: [
        QdrantPayloadField(name: "city", type: .keyword, isIndexed: true),
        QdrantPayloadField(name: "body", type: .text, isIndexed: true),
        QdrantPayloadField(name: "pop", type: .float, isIndexed: true),
        QdrantPayloadField(name: "seen", type: .datetime, isIndexed: true),
        QdrantPayloadField(name: "count", type: .integer, isIndexed: false),
        QdrantPayloadField(name: "active", type: .bool, isIndexed: false),
        QdrantPayloadField(name: "note", type: .string, isIndexed: false),
        QdrantPayloadField(name: "tags", type: .array, isIndexed: false),
        QdrantPayloadField(name: "home", type: .geo, isIndexed: false),
        QdrantPayloadField(name: "a.b", type: .string, isIndexed: false)
    ]
)

func canonical(_ object: Any) -> String {
    (try? QdrantJSON.text(object)) ?? ""
}
