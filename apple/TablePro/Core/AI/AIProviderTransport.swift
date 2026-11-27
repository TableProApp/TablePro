//
//  AIProviderTransport.swift
//  TablePro
//

import Foundation
import TableProHTTP

struct AIHTTPReply {
    let data: Data
    let response: HTTPURLResponse

    var statusCode: Int { response.statusCode }
}

enum AIModelListReply {
    case unreachable(any Error)
    case notHTTP
    case rejected(AIHTTPReply)
    // Nil when the body is not JSON or has no array under the key.
    case entries([[String: Any]]?)
}

// The HTTP side every provider shares. A provider configures it and keeps only its wire format.
struct AIProviderTransport: Sendable {
    let configuredEndpoint: String
    let endpoint: AIEndpoint?
    let headers: [String: String]
    let forbiddenIsAuthFailure: Bool
    let session: URLSession

    init(
        endpoint: String,
        style: AIEndpointStyle,
        headers: [String: String],
        forbiddenIsAuthFailure: Bool = false,
        session: URLSession
    ) {
        self.configuredEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.endpoint = AIEndpoint(endpoint, style: style)
        self.headers = headers
        self.forbiddenIsAuthFailure = forbiddenIsAuthFailure
        self.session = session
    }

    static func bearer(_ apiKey: String?) -> [String: String] {
        guard let apiKey, !apiKey.isEmpty else { return [:] }
        return ["Authorization": "Bearer \(apiKey)"]
    }

    func url(_ resource: String, query: [URLQueryItem] = []) throws -> URL {
        guard let url = endpoint?.url(appending: resource, query: query) else {
            throw AIProviderError.invalidEndpoint(configuredEndpoint)
        }
        return url
    }

    func get(_ url: URL, timeout: TimeInterval? = AIProvider.modelListTimeout, authenticated: Bool = true) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let timeout {
            request.timeoutInterval = timeout
        }
        if authenticated {
            applyHeaders(to: &request)
        }
        return request
    }

    func post(_ url: URL, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func stream<Wire: ChatStreamWire>(
        _ wire: Wire,
        request: @escaping @Sendable () async throws -> URLRequest
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        SSEEventStream.make(
            session: session,
            treatForbiddenAsAuthFailure: forbiddenIsAuthFailure,
            wire: wire,
            buildRequest: request
        )
    }

    func modelList(at url: URL, key: String, authenticated: Bool = true) async -> AIModelListReply {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(
                for: get(url, authenticated: authenticated),
                delegate: SameOriginRedirects.shared
            )
        } catch {
            return .unreachable(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else { return .notHTTP }
        guard httpResponse.statusCode == 200 else {
            return .rejected(AIHTTPReply(data: data, response: httpResponse))
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return .entries(json?[key] as? [[String: Any]])
    }

    // A rejected key throws; any other answer is the provider's to judge.
    func connectionReply(to request: URLRequest) async throws -> AIHTTPReply? {
        let (data, response) = try await session.data(for: request, delegate: SameOriginRedirects.shared)
        guard let httpResponse = response as? HTTPURLResponse else { return nil }
        if httpResponse.statusCode == 401 || (httpResponse.statusCode == 403 && forbiddenIsAuthFailure) {
            throw AIProviderError.authenticationFailed("")
        }
        return AIHTTPReply(data: data, response: httpResponse)
    }

    func httpError(_ reply: AIHTTPReply, url: URL?) -> AIProviderError {
        AIProviderError.mapHTTPError(
            statusCode: reply.statusCode,
            body: String(data: reply.data, encoding: .utf8) ?? "",
            treatForbiddenAsAuthFailure: forbiddenIsAuthFailure,
            requestURL: url
        )
    }

    private func applyHeaders(to request: inout URLRequest) {
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
    }
}
