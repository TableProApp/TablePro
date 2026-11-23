//
//  ChatToolCallRepair.swift
//  TablePro
//

import Foundation

// Providers reject a request in which a tool call has no result, or a result has no call. A stopped round, a
// transcript saved by a build that left one open, or one cut short on disk must still be sendable.
enum ChatToolCallRepair {
    static let interruptedContent = "This tool call was interrupted before it returned a result."
    static let stoppedBeforeRunContent = "The user stopped the response before this tool call ran."

    static func answeringEveryToolCall(_ turns: [ChatTurnWire]) -> [ChatTurnWire] {
        var repaired: [ChatTurnWire] = []
        repaired.reserveCapacity(turns.count)
        var owed: [ToolResultBlock] = []

        for (index, original) in turns.enumerated() {
            var turn = original
            if turn.role == .user {
                turn.blocks = droppingOrphanResults(turn.blocks, after: repaired.last)
            }
            if !owed.isEmpty {
                if turn.role == .user, !toolResultIds(in: turn).isEmpty {
                    turn.blocks.insert(contentsOf: owed.map { .toolResult($0) }, at: 0)
                } else {
                    repaired.append(ChatTurnWire(role: .user, blocks: owed.map { .toolResult($0) }))
                }
                owed = []
            }
            // A turn that held only results for calls no longer in the transcript has nothing left to send.
            if turn.blocks.isEmpty, !original.blocks.isEmpty { continue }
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

    // A result answers a call only in the turn right after it.
    private static func droppingOrphanResults(
        _ blocks: [ChatContentBlockWire],
        after previous: ChatTurnWire?
    ) -> [ChatContentBlockWire] {
        let calls = previous?.role == .assistant ? toolUseIds(in: previous) : []
        return blocks.filter { block in
            guard case .toolResult(let result) = block.kind else { return true }
            return calls.contains(result.toolUseId)
        }
    }

    private static func toolUseIds(in turn: ChatTurnWire?) -> Set<String> {
        Set((turn?.blocks ?? []).compactMap { block -> String? in
            guard case .toolUse(let call) = block.kind else { return nil }
            return call.id
        })
    }

    private static func toolResultIds(in turn: ChatTurnWire) -> Set<String> {
        Set(turn.blocks.compactMap { block -> String? in
            guard case .toolResult(let result) = block.kind else { return nil }
            return result.toolUseId
        })
    }
}
