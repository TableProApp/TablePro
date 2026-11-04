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
    // A ring once full: each new entry takes the slot of the oldest, which is released then.
    private var storage: [LiveMessageEntry] = []
    private var oldest = 0
    private(set) var droppedCount = 0
    private var nextId = 0

    var entries: [LiveMessageEntry] { Array(storage[oldest...]) + storage[..<oldest] }

    init(capacity: Int = defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ messages: [PluginLiveMessage]) {
        for message in messages {
            push(.message(message))
        }
    }

    mutating func appendGap(reason: String) {
        push(.gap(reason: reason))
    }

    mutating func clear() {
        storage.removeAll(keepingCapacity: true)
        oldest = 0
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
        let entry = LiveMessageEntry(id: nextId, kind: kind)
        nextId += 1
        guard storage.count == capacity else {
            storage.append(entry)
            return
        }
        storage[oldest] = entry
        oldest = oldest + 1 == capacity ? 0 : oldest + 1
        droppedCount += 1
    }
}
