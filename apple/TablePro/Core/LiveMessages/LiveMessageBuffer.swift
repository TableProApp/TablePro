//
//  LiveMessageBuffer.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct LiveMessageEntry: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case message(PluginLiveMessage)
        // The connection dropped: messages sent until it came back were not received.
        case gap(reason: String)
    }

    let id: Int
    let kind: Kind

    var message: PluginLiveMessage? {
        if case .message(let message) = kind { return message }
        return nil
    }

    func matches(_ filter: String) -> Bool {
        guard !filter.isEmpty else { return true }
        guard let message else { return true }
        return message.channel.localizedCaseInsensitiveContains(filter)
            || message.payload.localizedCaseInsensitiveContains(filter)
            || (message.key?.localizedCaseInsensitiveContains(filter) ?? false)
    }
}

// The newest `capacity` entries. A pause freezes what is shown, never what is kept, so resuming loses nothing up to the cap.
internal struct LiveMessageBuffer: Sendable {
    static let defaultCapacity = 10_000

    let capacity: Int
    private(set) var entries: [LiveMessageEntry] = []
    private(set) var droppedCount = 0
    private var nextId = 0

    init(capacity: Int = defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ messages: [PluginLiveMessage]) {
        for message in messages {
            push(.message(message))
        }
        trim()
    }

    mutating func appendGap(reason: String) {
        push(.gap(reason: reason))
        trim()
    }

    mutating func clear() {
        entries.removeAll(keepingCapacity: true)
        droppedCount = 0
    }

    func visible(filter: String) -> [LiveMessageEntry] {
        Self.filter(entries, by: filter)
    }

    static func filter(_ entries: [LiveMessageEntry], by filter: String) -> [LiveMessageEntry] {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { $0.matches(trimmed) }
    }

    private mutating func push(_ kind: LiveMessageEntry.Kind) {
        entries.append(LiveMessageEntry(id: nextId, kind: kind))
        nextId += 1
    }

    private mutating func trim() {
        let excess = entries.count - capacity
        guard excess > 0 else { return }
        entries.removeFirst(excess)
        droppedCount += excess
    }
}
