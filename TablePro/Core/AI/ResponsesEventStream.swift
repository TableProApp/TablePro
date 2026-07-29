//
//  ResponsesEventStream.swift
//  TablePro
//

import Foundation

enum ResponsesEventStream {
    static func make(
        session: URLSession,
        treatForbiddenAsAuthFailure: Bool = false,
        buildRequest: @escaping @Sendable () async throws -> URLRequest,
        refreshOnUnauthorized: (@Sendable () async throws -> Void)? = nil
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        SSEEventStream.make(
            session: session,
            treatForbiddenAsAuthFailure: treatForbiddenAsAuthFailure,
            buildRequest: buildRequest,
            decodeLine: { OpenAIResponsesProvider.decodeStreamLine($0) },
            makeState: { ResponsesStreamState() },
            parse: { try OpenAIResponsesProvider.parseEvent($0, state: &$1) },
            finalEvents: { state in state.finalUsageEvent().map { [$0] } ?? [] },
            refreshOnUnauthorized: refreshOnUnauthorized
        )
    }
}
