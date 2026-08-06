import Foundation

public struct R2SQLHTTPRequest: Sendable, Equatable {
    public let url: URL
    public let headers: [String: String]
    public let body: Data
    public let timeoutSeconds: Int

    public init(url: URL, headers: [String: String], body: Data, timeoutSeconds: Int) {
        self.url = url
        self.headers = headers
        self.body = body
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct R2SQLHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol R2SQLTransport: Sendable {
    func send(_ request: R2SQLHTTPRequest) async throws -> R2SQLHTTPResponse
}
