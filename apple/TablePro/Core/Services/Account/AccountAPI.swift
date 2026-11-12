//
//  AccountAPI.swift
//  TablePro
//

import Foundation
import TableProCloudAPI

internal enum AccountAPI {
    static func client(
        configuration: AccountConfiguration,
        transport: any ClientTransport,
        session: AccountSession
    ) -> Client {
        Client(
            serverURL: configuration.apiServerURL,
            configuration: Configuration(dateTranscoder: RFC3339DateTranscoder()),
            transport: transport,
            middlewares: [BearerTokenMiddleware(session: session)]
        )
    }

    static func transport(session: URLSession) -> any ClientTransport {
        URLSessionTransport(configuration: .init(session: session))
    }
}

// Sends the session's access token, and on a 401 refreshes once and retries.
internal struct BearerTokenMiddleware: ClientMiddleware {
    let session: AccountSession

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let token = try await session.accessToken()
        var request = request
        request.headerFields[.authorization] = "Bearer \(token.value)"
        let (response, responseBody) = try await next(request, body, baseURL)
        guard response.status == .unauthorized else {
            return (response, responseBody)
        }
        let refreshed = try await session.refresh(replacing: token)
        request.headerFields[.authorization] = "Bearer \(refreshed.value)"
        return try await next(request, body, baseURL)
    }
}

// Go writes RFC 3339 with fractional seconds only when they are not zero.
internal struct RFC3339DateTranscoder: DateTranscoder {
    func encode(_ date: Date) throws -> String {
        date.formatted(.iso8601)
    }

    func decode(_ text: String) throws -> Date {
        if let date = try? Date(text, strategy: .iso8601) {
            return date
        }
        return try Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
