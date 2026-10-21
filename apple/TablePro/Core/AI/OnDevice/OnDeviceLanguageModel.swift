//
//  OnDeviceLanguageModel.swift
//  TablePro
//

import Foundation

struct OnDeviceRequest: Equatable, Sendable {
    let instructions: String
    let prompt: String
}

struct OnDeviceUnavailableError: LocalizedError {
    let availability: AppleIntelligenceAvailability

    var errorDescription: String? {
        availability.unavailableExplanation
    }
}

enum OnDeviceFit: Equatable, Sendable {
    case fits(index: Int, maximumResponseTokens: Int)
    case tooLarge
}

protocol OnDeviceLanguageModel: Sendable {
    var availability: AppleIntelligenceAvailability { get }
    var contextSize: Int { get }
    func tokenCount(for request: OnDeviceRequest) async -> Int
    func streamResponse(to request: OnDeviceRequest, maximumResponseTokens: Int) -> AsyncThrowingStream<String, Error>
}

extension OnDeviceLanguageModel {
    func fit(_ candidates: [OnDeviceRequest], reservingForReply reserve: Int) async -> OnDeviceFit {
        let limit = contextSize - OnDeviceTokenBudget.transcriptMargin
        for (index, candidate) in candidates.enumerated() {
            guard !Task.isCancelled else { return .tooLarge }
            let tokens = await tokenCount(for: candidate)
            if tokens + reserve <= limit {
                return .fits(index: index, maximumResponseTokens: limit - tokens)
            }
        }
        return .tooLarge
    }
}

enum OnDeviceSnapshot {
    // Scalars, not Characters: a snapshot can extend the last grapheme (a ZWJ emoji, a combining mark),
    // and a Character prefix check would then reject every later snapshot.
    static func delta(from emitted: String, to content: String) -> String? {
        guard content.unicodeScalars.starts(with: emitted.unicodeScalars) else { return nil }
        return String(content.unicodeScalars.dropFirst(emitted.unicodeScalars.count))
    }
}

enum OnDeviceTokenBudget {
    // The session wraps instructions and prompt in role markers that two separate counts miss.
    static let transcriptMargin = 64

    // Measured on the macOS 27 model (scripts/probes/check-on-device-model.sh): SQL and Markdown tables
    // run 2.7 to 2.9 ASCII characters a token, CJK about 2.2. ASCII at two a token and anything else at one
    // keeps the estimate high where tokenCount(for:) is missing (macOS 26.0 to 26.3).
    static let asciiCharactersPerToken = 2
    static let estimateOverhead = 64

    static func estimatedTokens(in request: OnDeviceRequest) -> Int {
        var ascii = 0
        var other = 0
        for scalar in request.instructions.unicodeScalars + request.prompt.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { other += 1 }
        }
        return (ascii + asciiCharactersPerToken - 1) / asciiCharactersPerToken + other + estimateOverhead
    }
}
