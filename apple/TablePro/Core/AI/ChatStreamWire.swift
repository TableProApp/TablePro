//
//  ChatStreamWire.swift
//  TablePro
//

import Foundation

protocol ChatStreamState {
    init()
    var inputTokens: Int { get set }
    var outputTokens: Int { get set }
    // Set once the provider sent anything, or said the response is over.
    var receivedOutput: Bool { get set }
}

extension ChatStreamState {
    func finalUsageEvent() -> ChatStreamEvent? {
        guard inputTokens > 0 || outputTokens > 0 else { return nil }
        return .usage(AITokenUsage(inputTokens: inputTokens, outputTokens: outputTokens))
    }
}

// One provider's response stream. `events(from:state:)` and `finalEvents(_:)` are what every provider runs around it.
protocol ChatStreamWire: Sendable {
    associatedtype State: ChatStreamState

    func decodeLine(_ line: String) -> [String: Any]?
    func parse(_ json: [String: Any], state: inout State) throws -> [ChatStreamEvent]
    func closingEvents(_ state: inout State) -> [ChatStreamEvent]
}

extension ChatStreamWire {
    func decodeLine(_ line: String) -> [String: Any]? {
        SSEEventStream.jsonPayload(line)
    }

    func closingEvents(_ state: inout State) -> [ChatStreamEvent] {
        []
    }

    func events(from json: [String: Any], state: inout State) throws -> [ChatStreamEvent] {
        if let error = AIProviderError.streamError(in: json) { throw error }
        let events = try parse(json, state: &state)
        if !events.isEmpty {
            state.receivedOutput = true
        }
        return events
    }

    // A base URL that answers 200 with a web page decodes to nothing, which would otherwise read as an empty reply.
    func finalEvents(_ state: State) throws -> [ChatStreamEvent] {
        guard state.receivedOutput else {
            throw AIProviderError.streamingFailed(
                String(localized: "The provider ended the response without sending any content.")
            )
        }
        var state = state
        return closingEvents(&state) + [state.finalUsageEvent()].compactMap { $0 }
    }
}

struct ToolCallTracker<Key: Hashable> {
    private var ids: [Key: String] = [:]
    private var order: [Key] = []

    var isEmpty: Bool { ids.isEmpty }

    func id(for key: Key) -> String? {
        ids[key]
    }

    // A second start for a call that is still open opens nothing new.
    mutating func start(
        _ key: Key,
        id: String,
        name: String,
        providerMetadata: [String: String]? = nil
    ) -> ChatStreamEvent? {
        guard ids[key] == nil else { return nil }
        ids[key] = id
        order.append(key)
        return .toolUseStart(id: id, name: name, providerMetadata: providerMetadata)
    }

    mutating func end(_ key: Key) -> ChatStreamEvent? {
        guard let id = ids.removeValue(forKey: key) else { return nil }
        order.removeAll { $0 == key }
        return .toolUseEnd(id: id)
    }

    mutating func endAll() -> [ChatStreamEvent] {
        let events = order.compactMap { ids[$0] }.map { ChatStreamEvent.toolUseEnd(id: $0) }
        ids.removeAll()
        order.removeAll()
        return events
    }
}
