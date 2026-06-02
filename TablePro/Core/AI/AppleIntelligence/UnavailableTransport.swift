//
//  UnavailableTransport.swift
//  TablePro
//

import Foundation

final class UnavailableTransport: ChatTransport {
    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    func streamChat(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let reason = reason
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: AIProviderError.streamingFailed(reason))
        }
    }

    func fetchAvailableModels() async throws -> [String] { [] }

    func testConnection() async throws -> Bool {
        throw AIProviderError.streamingFailed(reason)
    }
}
