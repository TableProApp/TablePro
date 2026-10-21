//
//  SystemOnDeviceLanguageModel.swift
//  TablePro
//

import Foundation
import FoundationModels
import os

struct SystemOnDeviceLanguageModel: OnDeviceLanguageModel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AppleIntelligence")

    var availability: AppleIntelligenceAvailability {
        guard #available(macOS 26, *) else { return .unavailable(.requiresNewerMacOS) }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(.appleIntelligenceNotEnabled)
        case .unavailable(.modelNotReady):
            return .unavailable(.modelNotReady)
        case .unavailable:
            return .unavailable(.unknown)
        }
    }

    var contextSize: Int {
        guard #available(macOS 26, *) else { return 0 }
        return SystemLanguageModel.default.contextSize
    }

    func tokenCount(for request: OnDeviceRequest) async -> Int {
        if #available(macOS 26.4, *) {
            let model = SystemLanguageModel.default
            do {
                let instructions = try await model.tokenCount(for: Instructions(request.instructions))
                let prompt = try await model.tokenCount(for: request.prompt)
                return instructions + prompt
            } catch {
                Self.logger.warning("Token count failed, estimating: \(error.publicLogShape, privacy: .public)")
            }
        }
        return OnDeviceTokenBudget.estimatedTokens(in: request)
    }

    func streamResponse(to request: OnDeviceRequest, maximumResponseTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard #available(macOS 26, *) else {
                continuation.finish(throwing: OnDeviceUnavailableError(availability: .unavailable(.requiresNewerMacOS)))
                return
            }
            let task = Task {
                do {
                    let session = LanguageModelSession(model: .default, instructions: request.instructions)
                    let options = GenerationOptions(maximumResponseTokens: maximumResponseTokens)
                    var emitted = ""
                    for try await snapshot in session.streamResponse(to: request.prompt, options: options) {
                        let content = snapshot.content
                        guard let delta = OnDeviceSnapshot.delta(from: emitted, to: content) else {
                            Self.logger.fault("On-device snapshot did not extend the text already shown")
                            continue
                        }
                        emitted = content
                        if !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
