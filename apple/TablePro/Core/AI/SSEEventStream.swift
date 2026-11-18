//
//  SSEEventStream.swift
//  TablePro
//

import Foundation
import TableProHTTP

enum SSEEventStream {
    // WHATWG event stream: the field ends at the colon, and one space after it is optional.
    static func dataPayload(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let value = line.dropFirst(5)
        return String(value.first == " " ? value.dropFirst() : value)
    }

    static func jsonPayload(_ line: String) -> [String: Any]? {
        guard let payload = dataPayload(line),
              payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    static func make<Wire: ChatStreamWire>(
        session: URLSession,
        treatForbiddenAsAuthFailure: Bool = false,
        wire: Wire,
        buildRequest: @escaping @Sendable () async throws -> URLRequest,
        refreshOnUnauthorized: (@Sendable () async throws -> Void)? = nil
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try await buildRequest()
                    var (bytes, response) = try await session.bytes(for: request, delegate: SameOriginRedirects.shared)
                    if (response as? HTTPURLResponse)?.statusCode == 401,
                       let refreshOnUnauthorized {
                        try await refreshOnUnauthorized()
                        (bytes, response) = try await session.bytes(for: buildRequest(), delegate: SameOriginRedirects.shared)
                    }

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw AIProviderError.networkError("Invalid response")
                    }
                    guard httpResponse.statusCode == 200 else {
                        let body = try await AIProvider.collectErrorBody(from: bytes)
                        throw AIProviderError.mapHTTPError(
                            statusCode: httpResponse.statusCode,
                            body: body,
                            treatForbiddenAsAuthFailure: treatForbiddenAsAuthFailure,
                            requestURL: request.url
                        )
                    }

                    var state = Wire.State()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let json = wire.decodeLine(line) else { continue }
                        for event in try wire.events(from: json, state: &state) {
                            continuation.yield(event)
                        }
                    }
                    for final in try wire.finalEvents(state) {
                        continuation.yield(final)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
