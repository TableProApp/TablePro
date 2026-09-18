import Foundation
@testable import TableProWeaviateCore

final class FakeWeaviateTransport: WeaviateTransport, @unchecked Sendable {
    struct Route: Equatable {
        let method: String
        let path: String
    }

    var responses: [String: WeaviateHTTPResponse] = [:]
    var requests: [WeaviateHTTPRequest] = []
    var error: WeaviateError?

    func send(_ request: WeaviateHTTPRequest) async throws -> WeaviateHTTPResponse {
        if let error {
            throw error
        }
        requests.append(request)
        let key = Self.key(method: request.method, url: request.url)
        if let response = responses[key] ?? responses[request.url.path] {
            return response
        }
        throw WeaviateError.malformedResponse("No fake response for \(key)")
    }

    func cancelAll() {}

    func respond(method: String, path: String, status: Int, json: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        responses[Self.key(method: method, path: path)] = WeaviateHTTPResponse(statusCode: status, body: data)
    }

    func respond(method: String, path: String, status: Int, body: String) {
        responses[Self.key(method: method, path: path)] = WeaviateHTTPResponse(
            statusCode: status,
            body: Data(body.utf8)
        )
    }

    static func key(method: String, path: String) -> String {
        "\(method.uppercased()) \(path)"
    }

    static func key(method: String, url: URL) -> String {
        key(method: method, path: url.path)
    }
}

func testSettings(auth: WeaviateAuth = WeaviateAuth(method: .none)) -> WeaviateConnectionSettings {
    WeaviateConnectionSettings(
        host: "localhost",
        port: 8_080,
        usesTLS: false,
        auth: auth,
        skipTLSVerify: false
    )
}

func testClient(
    transport: FakeWeaviateTransport,
    auth: WeaviateAuth = WeaviateAuth(method: .none)
) -> WeaviateClient {
    WeaviateClient(settings: testSettings(auth: auth), transport: transport, timeout: { 30 })
}

enum WeaviateFixtures {
    static let articleUUID = "c8f5c3e0-1b2a-4d3e-9f10-111213141516"

    static var schema: [String: Any] {
        [
            "classes": [
                [
                    "class": "Article",
                    "vectorizer": "none",
                    "properties": [
                        ["name": "title", "dataType": ["text"]],
                        ["name": "wordCount", "dataType": ["int"]]
                    ]
                ]
            ]
        ]
    }

    static var objects: [String: Any] {
        [
            "objects": [
                [
                    "id": articleUUID,
                    "class": "Article",
                    "properties": ["title": "Hello", "wordCount": 12],
                    "vector": [0.1, 0.2, 0.3]
                ]
            ],
            "totalResults": 1
        ]
    }

    static var graphqlGet: [String: Any] {
        [
            "data": [
                "Get": [
                    "Article": [
                        [
                            "title": "Hello",
                            "wordCount": 12,
                            "_additional": [
                                "id": articleUUID,
                                "vector": [0.1, 0.2]
                            ]
                        ]
                    ]
                ]
            ]
        ]
    }

    static var meta: [String: Any] {
        ["version": "1.27.0"]
    }
}
