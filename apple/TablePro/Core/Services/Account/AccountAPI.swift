//
//  AccountAPI.swift
//  TablePro
//

import Foundation
import TableProCloudAPI

internal enum AccountAPI {
    // The server URL is the bearer middleware's to set, from the server the core signs in to.
    static func client(backend: any AccountBackend, transport: any ClientTransport) -> Client {
        Client(
            serverURL: AccountServer.production.apiBaseURL,
            configuration: Configuration(dateTranscoder: RFC3339DateTranscoder()),
            transport: transport,
            middlewares: [AccountBearerMiddleware(backend: backend)]
        )
    }

    // No bearer, and never the company server: a shared link is a tablepro.app link, opened signed in or not.
    static func publicClient(serverURL: URL, transport: any ClientTransport) -> Client {
        Client(
            serverURL: serverURL,
            configuration: Configuration(dateTranscoder: RFC3339DateTranscoder()),
            transport: transport
        )
    }

    static func transport(session: URLSession) -> any ClientTransport {
        URLSessionTransport(configuration: .init(session: session))
    }
}

// Sends the core's access token to the server it was issued for, and on a 401 tells the core and retries once, on
// that server only: a body sent to one server never goes to another.
internal struct AccountBearerMiddleware: ClientMiddleware {
    let backend: any AccountBackend

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let access = try await backend.accessToken()
        var request = request
        request.headerFields[.authorization] = "Bearer \(access.token)"
        let (response, responseBody) = try await next(request, body, access.apiBaseURL)
        guard response.status == .unauthorized else {
            return (response, responseBody)
        }
        await backend.accessTokenRejected(access.token)
        let refreshed = try await backend.accessToken()
        guard refreshed.apiBaseURL == access.apiBaseURL else { throw AccountError.signedOut }
        request.headerFields[.authorization] = "Bearer \(refreshed.token)"
        return try await next(request, body, access.apiBaseURL)
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
