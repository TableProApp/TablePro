import Foundation

public struct QdrantHTTPRequest: Sendable, Equatable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data?
    public let timeoutInterval: TimeInterval

    public init(method: String, url: URL, headers: [String: String], body: Data?, timeoutInterval: TimeInterval) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeoutInterval = timeoutInterval
    }
}

public struct QdrantHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    public var json: Any? {
        try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
    }

    public var text: String {
        String(data: body, encoding: .utf8) ?? ""
    }
}

// The URLSession transport lives in the plugin: the app links this module for the query classifier,
// and an Objective-C class compiled into both would be registered twice in one process.
public protocol QdrantTransport: Sendable {
    func send(_ request: QdrantHTTPRequest) async throws -> QdrantHTTPResponse
    func cancelAll()
}
