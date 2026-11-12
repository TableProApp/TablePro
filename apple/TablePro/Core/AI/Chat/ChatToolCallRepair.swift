//
//  ChatToolCallRepair.swift
//  TablePro
//

import Foundation

// Providers reject a request in which a tool call has no result. A stopped round, or a transcript
// saved by a build that left one open, must still be sendable.
enum ChatToolCallRepair {
    static let interruptedContent = "This tool call was interrupted before it returned a result."
    static let stoppedBeforeRunContent = "The user stopped the response before this tool call ran."

    static func answeringEveryToolCall(_ turns: [ChatTurnWire]) -> [ChatTurnWire] {
        var repaired: [ChatTurnWire] = []
        repaired.reserveCapacity(turns.count)
        var owed: [ToolResultBlock] = []

        for (index, original) in turns.enumerated() {
            var turn = original
            if !owed.isEmpty {
                if turn.role == .user, !toolResultIds(in: turn).isEmpty {
                    turn.blocks.insert(contentsOf: owed.map { .toolResult($0) }, at: 0)
                } else {
                    repaired.append(ChatTurnWire(role: .user, blocks: owed.map { .toolResult($0) }))
                }
                owed = []
            }
            repaired.append(turn)
            guard turn.role == .assistant else { continue }
            owed = unansweredResults(for: turn, next: index + 1 < turns.count ? turns[index + 1] : nil)
        }

        if !owed.isEmpty {
            repaired.append(ChatTurnWire(role: .user, blocks: owed.map { .toolResult($0) }))
        }
        return repaired
    }

    // A stored card has nothing left to answer it, so storage and a loaded transcript never hold `.pending`.
    static func settlingPendingApprovals(_ turns: [ChatTurnWire]) -> [ChatTurnWire] {
        turns.map { turn in
            var settled = turn
            settled.blocks = turn.blocks.map { block in
                guard case .toolUse(var call) = block.kind, case .pending = call.approvalState else { return block }
                call.approvalState = .cancelled
                return ChatContentBlockWire(id: block.id, kind: .toolUse(call))
            }
            return settled
        }
    }

    static func interruptedResults(for blocks: [ToolUseBlock]) -> [ToolResultBlock] {
        blocks.map { block in
            switch block.approvalState {
            case .approved, .pending:
                return ToolResultBlock(toolUseId: block.id, content: stoppedBeforeRunContent, isError: true)
            case .cancelled:
                return ToolResultBlock(toolUseId: block.id, content: "User cancelled this tool call.", isError: true)
            case .denied(let reason):
                return ToolResultBlock(toolUseId: block.id, content: reason, isError: true)
            }
        }
    }

    private static func unansweredResults(for turn: ChatTurnWire, next: ChatTurnWire?) -> [ToolResultBlock] {
        var answered = toolResultIds(in: turn)
        if let next, next.role == .user {
            answered.formUnion(toolResultIds(in: next))
        }
        var owed: [ToolResultBlock] = []
        for block in turn.blocks {
            guard case .toolUse(let call) = block.kind, !answered.contains(call.id) else { continue }
            answered.insert(call.id)
            owed.append(ToolResultBlock(toolUseId: call.id, content: unansweredContent(for: call), isError: true))
        }
        return owed
    }

    // An approved call with no result may have run; a cancelled or denied one never did.
    private static func unansweredContent(for call: ToolUseBlock) -> String {
        switch call.approvalState {
        case .approved, .pending:
            return interruptedContent
        case .cancelled:
            return stoppedBeforeRunContent
        case .denied(let reason):
            return reason
        }
    }

    private static func toolResultIds(in turn: ChatTurnWire) -> Set<String> {
        Set(turn.blocks.compactMap { block -> String? in
            guard case .toolResult(let result) = block.kind else { return nil }
            return result.toolUseId
        })
    }
}
