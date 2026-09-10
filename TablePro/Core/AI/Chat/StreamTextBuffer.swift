//
//  StreamTextBuffer.swift
//  TablePro
//

import Foundation

@MainActor
final class StreamTextBuffer {
    private var text: String = ""
    private var usage: AITokenUsage?
    private var reasoningByProviderID: [String: String] = [:]
    private var reasoningOrder: [String] = []

    var hasBufferedText: Bool { !text.isEmpty || usage != nil }

    var hasBufferedReasoning: Bool { !reasoningOrder.isEmpty }

    func appendText(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        text += chunk
    }

    func setUsage(_ newUsage: AITokenUsage) {
        usage = newUsage
    }

    func appendReasoning(providerBlockID: String, text chunk: String) {
        guard !chunk.isEmpty else { return }
        if reasoningByProviderID[providerBlockID] == nil {
            reasoningOrder.append(providerBlockID)
        }
        reasoningByProviderID[providerBlockID, default: ""] += chunk
    }

    func drainText() -> (text: String, usage: AITokenUsage?) {
        let drained = (text: text, usage: usage)
        text = ""
        usage = nil
        return drained
    }

    func drainReasoning() -> [(providerBlockID: String, text: String)] {
        let drained = reasoningOrder.compactMap { providerBlockID -> (String, String)? in
            guard let chunk = reasoningByProviderID[providerBlockID], !chunk.isEmpty else { return nil }
            return (providerBlockID, chunk)
        }
        reasoningByProviderID.removeAll()
        reasoningOrder.removeAll()
        return drained
    }
}
