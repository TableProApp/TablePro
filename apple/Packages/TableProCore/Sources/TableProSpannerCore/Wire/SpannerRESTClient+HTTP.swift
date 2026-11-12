import Foundation
import os
import TableProGoogleCloud

internal struct SpannerHTTPCall: Sendable {
    enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case patch = "PATCH"
        case delete = "DELETE"
    }

    let method: Method
    let url: URL
    let body: Data?
    let replaySafe: Bool

    init(method: Method, url: URL, body: Data? = nil, replaySafe: Bool) {
        self.method = method
        self.url = url
        self.body = body
        self.replaySafe = replaySafe
    }
}

internal extension SpannerRESTClient {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SpannerRESTClient")
    private static let maximumErrorBodySize = 1_024 * 1_024

    func perform(_ call: SpannerHTTPCall) async throws -> Data {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await sendAuthorized(call)
                if (200..<300).contains(response.statusCode) {
                    return data
                }
                let error = SpannerAPIError.decode(httpStatus: response.statusCode, body: data)
                guard call.replaySafe, error.isUnavailable, attempt < retryDelays.count else { throw error }
            } catch let error as SpannerTransportError {
                guard call.replaySafe, case .network = error, attempt < retryDelays.count else { throw error }
            }
            Self.logger.debug("Retrying Spanner \(call.method.rawValue, privacy: .public) after attempt \(attempt + 1)")
            try await Task.sleep(for: retryDelays[attempt])
            attempt += 1
        }
    }

    func openStream(_ call: SpannerHTTPCall) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let token = try await bearerToken(for: call.url)
        var (response, chunks) = try await transport.stream(makeRequest(call, token: token))
        if response.statusCode == 401, token != nil, let tokenProvider {
            await tokenProvider.invalidateCachedToken()
            let fresh = try await tokenProvider.accessToken()
            (response, chunks) = try await transport.stream(makeRequest(call, token: fresh))
        }
        guard (200..<300).contains(response.statusCode) else {
            let body = try await Self.collect(chunks, limit: Self.maximumErrorBodySize)
            throw SpannerAPIError.decode(httpStatus: response.statusCode, body: body)
        }
        return (response, chunks)
    }

    static func events(
        from chunks: AsyncThrowingStream<Data, Error>,
        httpStatus: Int
    ) -> AsyncThrowingStream<SpannerStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    var decoder = SpannerStreamDecoder(httpStatus: httpStatus)
                    for try await chunk in chunks {
                        for event in try decoder.consume(chunk) {
                            continuation.yield(event)
                        }
                    }
                    try Task.checkCancellation()
                    for event in try decoder.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try JSONEncoder().encode(value)
    }

    func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Self.logger.error("Spanner response did not decode as \(String(describing: type), privacy: .public)")
            throw SpannerTransportError.invalidResponse
        }
    }

    private func sendAuthorized(_ call: SpannerHTTPCall) async throws -> (Data, HTTPURLResponse) {
        let token = try await bearerToken(for: call.url)
        let (data, response) = try await transport.send(makeRequest(call, token: token))
        guard response.statusCode == 401, token != nil, let tokenProvider else {
            return (data, response)
        }
        await tokenProvider.invalidateCachedToken()
        let fresh = try await tokenProvider.accessToken()
        return try await transport.send(makeRequest(call, token: fresh))
    }

    private func bearerToken(for url: URL) async throws -> String? {
        guard let tokenProvider, GoogleEndpointPolicy.isTrustedGoogleAPI(url) else { return nil }
        return try await tokenProvider.accessToken()
    }

    private func makeRequest(_ call: SpannerHTTPCall, token: String?) -> URLRequest {
        var request = URLRequest(url: call.url)
        request.httpMethod = call.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = call.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func collect(_ chunks: AsyncThrowingStream<Data, Error>, limit: Int) async throws -> Data {
        var body = Data()
        for try await chunk in chunks {
            body.append(chunk)
            if body.count >= limit {
                break
            }
        }
        return body
    }
}

internal struct SpannerDatabaseResponse: Decodable {
    let databaseDialect: String?
}

internal struct SpannerNamedResource: Decodable {
    let name: String

    private enum CodingKeys: String, CodingKey {
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

internal struct SpannerTransactionResponse: Decodable {
    let id: String?
}

internal struct SpannerDDLResponse: Decodable {
    let statements: [String]

    private enum CodingKeys: String, CodingKey {
        case statements
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statements = try container.decodeArrayIfPresent(String.self, forKey: .statements)
    }
}

internal struct SpannerOperationResponse: Decodable {
    let name: String
    let done: Bool
    let error: SpannerStatusPayload?

    private enum CodingKeys: String, CodingKey {
        case name
        case done
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        done = try container.decodeIfPresent(Bool.self, forKey: .done) ?? false
        error = try container.decodeIfPresent(SpannerStatusPayload.self, forKey: .error)
    }
}

internal struct SpannerCreateSessionBody: Encodable {
    struct Session: Encodable {
        let multiplexed: Bool?
        let labels: [String: String]
    }

    let session: Session
}

internal struct SpannerBeginTransactionBody: Encodable {
    struct Options: Encodable {
        struct ReadWrite: Encodable {}

        let readWrite = ReadWrite()
    }

    let options = Options()
}

internal struct SpannerTransactionIdBody: Encodable {
    let transactionId: String
}

internal struct SpannerUpdateDdlBody: Encodable {
    let statements: [String]
}
