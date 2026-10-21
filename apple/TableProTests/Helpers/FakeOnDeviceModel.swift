//
//  FakeOnDeviceModel.swift
//  TableProTests
//

import Foundation
@testable import TablePro

final class FakeOnDeviceModel: OnDeviceLanguageModel, @unchecked Sendable {
    let availability: AppleIntelligenceAvailability
    let contextSize: Int

    private let lock = NSLock()
    private let reply: [String]
    private let tokens: @Sendable (OnDeviceRequest) -> Int
    private var counted: [OnDeviceRequest] = []
    private var streamed: [(request: OnDeviceRequest, maximumResponseTokens: Int)] = []

    init(
        availability: AppleIntelligenceAvailability = .available,
        contextSize: Int = 4_096,
        reply: [String] = ["Looks ", "fine."],
        tokens: @escaping @Sendable (OnDeviceRequest) -> Int = { ($0.instructions.count + $0.prompt.count) / 4 }
    ) {
        self.availability = availability
        self.contextSize = contextSize
        self.reply = reply
        self.tokens = tokens
    }

    var countedRequests: [OnDeviceRequest] {
        lock.withLock { counted }
    }

    var streamedRequests: [(request: OnDeviceRequest, maximumResponseTokens: Int)] {
        lock.withLock { streamed }
    }

    func tokenCount(for request: OnDeviceRequest) async -> Int {
        lock.withLock { counted.append(request) }
        return tokens(request)
    }

    func streamResponse(to request: OnDeviceRequest, maximumResponseTokens: Int) -> AsyncThrowingStream<String, Error> {
        lock.withLock { streamed.append((request, maximumResponseTokens)) }
        let chunks = reply
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}
