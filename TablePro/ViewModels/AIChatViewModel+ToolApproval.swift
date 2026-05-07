//
//  AIChatViewModel+ToolApproval.swift
//  TablePro
//

import Foundation

extension AIChatViewModel {
    func resolveAndAwaitApprovals(
        assembledBlocks: [ToolUseBlock],
        assistantID: UUID
    ) async -> [ToolUseBlock] {
        let initialBlocks = await MainActor.run { [weak self] () -> [ToolUseBlock] in
            guard let self else { return assembledBlocks }
            let initial = assembledBlocks.map { block -> ToolUseBlock in
                let state = self.computeInitialApprovalState(for: block.name)
                return ToolUseBlock(id: block.id, name: block.name, input: block.input, approvalState: state)
            }
            self.appendPendingToolUseBlocks(initial, assistantID: assistantID)
            return initial
        }

        var resolved: [ToolUseBlock] = []
        for block in initialBlocks {
            guard case .pending = block.approvalState else {
                resolved.append(block)
                continue
            }
            let decision = await ToolApprovalCenter.shared.awaitDecision(for: block.id)
            let finalState: ToolApprovalState
            switch decision {
            case .run:
                finalState = .approved
            case .alwaysAllow:
                await MainActor.run { [weak self] in
                    self?.persistAlwaysAllowed(toolName: block.name)
                }
                finalState = .approved
            case .cancel:
                finalState = .cancelled
            }
            await MainActor.run { [weak self] in
                self?.updateApprovalState(blockID: block.id, newState: finalState, assistantID: assistantID)
            }
            resolved.append(ToolUseBlock(
                id: block.id, name: block.name, input: block.input, approvalState: finalState
            ))
        }
        return resolved
    }

    @MainActor
    func computeInitialApprovalState(for toolName: String) -> ToolApprovalState {
        if !ChatToolRegistry.requiresApproval(toolName: toolName) {
            return .approved
        }
        if let connection, connection.aiAlwaysAllowedTools.contains(toolName) {
            return .approved
        }
        if let connection {
            if connection.safeModeLevel.blocksAllWrites {
                return .denied(reason: String(
                    localized: "Connection is read-only. Set safe mode to Confirm Writes or higher to allow this tool."
                ))
            }
            if !connection.safeModeLevel.requiresConfirmation {
                return .approved
            }
        }
        return .pending
    }

    @MainActor
    func appendPendingToolUseBlocks(_ blocks: [ToolUseBlock], assistantID: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        for block in blocks {
            messages[idx].blocks.append(.toolUse(block))
        }
    }

    @MainActor
    func updateApprovalState(blockID: String, newState: ToolApprovalState, assistantID: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        for blockIdx in messages[idx].blocks.indices {
            if case .toolUse(var block) = messages[idx].blocks[blockIdx], block.id == blockID {
                block.approvalState = newState
                messages[idx].blocks[blockIdx] = .toolUse(block)
                return
            }
        }
    }

    @MainActor
    func persistAlwaysAllowed(toolName: String) {
        guard var current = connection else { return }
        guard !current.aiAlwaysAllowedTools.contains(toolName) else { return }
        current.aiAlwaysAllowedTools.insert(toolName)
        connection = current
        ConnectionStorage.shared.updateConnection(current)
    }

    nonisolated static func synthesizeResults(
        for blocks: [ToolUseBlock],
        executed: [ToolResultBlock]
    ) -> [ToolResultBlock] {
        let executedById = Dictionary(uniqueKeysWithValues: executed.map { ($0.toolUseId, $0) })
        return blocks.map { block in
            switch block.approvalState {
            case .approved:
                return executedById[block.id] ?? ToolResultBlock(
                    toolUseId: block.id,
                    content: "Tool execution result missing.",
                    isError: true
                )
            case .pending:
                return ToolResultBlock(
                    toolUseId: block.id,
                    content: "Tool approval was not resolved.",
                    isError: true
                )
            case .cancelled:
                return ToolResultBlock(
                    toolUseId: block.id,
                    content: "User cancelled this tool call.",
                    isError: true
                )
            case .denied(let reason):
                return ToolResultBlock(toolUseId: block.id, content: reason, isError: true)
            }
        }
    }
}
