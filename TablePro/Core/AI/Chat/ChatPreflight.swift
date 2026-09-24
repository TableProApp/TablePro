//
//  ChatPreflight.swift
//  TablePro
//

import Foundation

struct ChatPreflight: Equatable, Sendable {
    enum Rejection: Equatable, Sendable {
        case systemPrompt
        case message
        case history

        var explanation: String {
            switch self {
            case .systemPrompt:
                return String(
                    localized: "Message too large. Try disabling 'Include schema' or 'Include query results' in AI settings."
                )
            case .message:
                return String(localized: "Message too large. Shorten it and send it again.")
            case .history:
                return String(localized: "This conversation is too long to continue. Start a new conversation and send your message there.")
            }
        }
    }

    static let characterLimit = 100_000

    let systemPromptLength: Int
    let messageLength: Int
    let historyLength: Int
    let messageTurnIDs: [UUID]
    let limit: Int

    init(systemPrompt: String?, turns: [ChatTurnWire], limit: Int = ChatPreflight.characterLimit) {
        let messageStart = Self.messageStart(in: turns)
        self.systemPromptLength = Self.length(of: systemPrompt ?? "")
        self.messageLength = turns[messageStart...].reduce(0) { $0 + Self.length(of: $1.plainText) }
        self.historyLength = turns[..<messageStart].reduce(0) { $0 + Self.length(of: $1.plainText) }
        self.messageTurnIDs = turns[messageStart...].map(\.id)
        self.limit = limit
    }

    var rejection: Rejection? {
        guard systemPromptLength + messageLength + historyLength > limit else { return nil }
        guard systemPromptLength + messageLength > limit else { return .history }
        return systemPromptLength >= messageLength ? .systemPrompt : .message
    }

    private static func messageStart(in turns: [ChatTurnWire]) -> Int {
        var start = turns.endIndex
        while start > turns.startIndex, isAuthoredUserTurn(turns[start - 1]) {
            start -= 1
        }
        return start
    }

    private static func isAuthoredUserTurn(_ turn: ChatTurnWire) -> Bool {
        guard turn.role == .user else { return false }
        return !turn.blocks.contains { block in
            if case .toolResult = block.kind { return true }
            return false
        }
    }

    private static func length(of text: String) -> Int {
        (text as NSString).length
    }
}
