//
//  SSEEventStream.swift
//  TablePro
//

import Foundation

enum SSEEventStream {
    static func make<State>(
        session: URLSession,
        treatForbiddenAsAuthFailure: Bool = false,
        buildRequest: @escaping @Sendable () async throws -> URLRequest,
        decodeLine: @escaping @Sendable (String) -> [String: Any]?,
        makeState: @escaping @Sendable () -> State,
        parse: @escaping @Sendable ([String: Any], inout State) throws -> [ChatStreamEvent],
        finalEvents: @escaping @Sendable (State) -> [ChatStreamEvent] = { _ in [] },
        refreshOnUnauthorized: (@Sendable () async throws -> Void)? = nil
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var (bytes, response) = try await session.bytes(for: buildRequest())
                    if (response as? HTTPURLResponse)?.statusCode == 401,
                       let refreshOnUnauthorized {
                        try await refreshOnUnauthorized()
                        (bytes, response) = try await session.bytes(for: buildRequest())
                    }

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw AIProviderError.networkError("Invalid response")
                    }
                    guard httpResponse.statusCode == 200 else {
                        let body = try await AIProvider.collectErrorBody(from: bytes)
                        throw AIProviderError.mapHTTPError(
                            statusCode: httpResponse.statusCode,
                            body: body,
                            treatForbiddenAsAuthFailure: treatForbiddenAsAuthFailure
                        )
                    }

                    var state = makeState()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let json = decodeLine(line) else { continue }
                        let events = try parse(json, &state)
                        for event in events { continuation.yield(event) }
                    }
                    for final in finalEvents(state) {
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
