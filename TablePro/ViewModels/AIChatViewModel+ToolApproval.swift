//
//  AIChatViewModel+ToolApproval.swift
//  TablePro
//

import Foundation

extension AIChatViewModel {
    func confirmAIAccess() {
        if let connectionID = connection?.id {
            sessionApprovedConnections.insert(connectionID)
        }
        guard case .awaitingApproval = streamingState else { return }
        streamingState = .idle
        startStreaming()
    }

    func denyAIAccess() {
        guard case .awaitingApproval = streamingState else { return }
        streamingState = .idle
        if let last = messages.last, last.role == .user {
            messages.removeLast()
        }
    }

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
        if !ChatToolRegistry.shared.requiresApproval(toolName: toolName) {
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
            messages[idx].appendBlock(.toolUse(block))
        }
    }

    @MainActor
    func updateApprovalState(blockID: String, newState: ToolApprovalState, assistantID: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        for chatBlock in messages[idx].blocks {
            if case .toolUse(var block) = chatBlock.kind, block.id == blockID {
                block.approvalState = newState
                chatBlock.setKind(.toolUse(block))
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
        services.connectionStorage.updateConnection(current)
    }

    func dispatchCopilotInvocation(
        block: ToolUseBlock,
        replyToken: ToolReplyToken,
        assistantID: UUID,
        mode: AIChatMode
    ) async {
        let context = ChatToolContext(
            connectionId: connection?.id,
            bridge: ChatToolBootstrap.bridge,
            authPolicy: ChatToolBootstrap.authPolicy
        )
        await handleCopilotToolInvocation(
            block: block, replyToken: replyToken,
            assistantID: assistantID, context: context, mode: mode
        )
    }

    func handleCopilotToolInvocation(
        block: ToolUseBlock,
        replyToken: ToolReplyToken,
        assistantID: UUID,
        context: ChatToolContext,
        mode: AIChatMode
    ) async {
        let initialState = computeInitialApprovalState(for: block.name)
        let pendingBlock = ToolUseBlock(
            id: block.id, name: block.name, input: block.input, approvalState: initialState
        )
        appendPendingToolUseBlocks([pendingBlock], assistantID: assistantID)

        let finalState: ToolApprovalState
        if case .pending = initialState {
            let decision = await ToolApprovalCenter.shared.awaitDecision(for: block.id)
            switch decision {
            case .run:
                finalState = .approved
            case .alwaysAllow:
                persistAlwaysAllowed(toolName: block.name)
                finalState = .approved
            case .cancel:
                finalState = .cancelled
            }
            updateApprovalState(blockID: block.id, newState: finalState, assistantID: assistantID)
        } else {
            finalState = initialState
        }

        let result: ChatToolResult
        switch finalState {
        case .approved:
            guard ChatToolRegistry.shared.isToolAllowed(name: block.name, in: mode) else {
                result = ChatToolResult(
                    content: "Tool '\(block.name)' is not available in \(mode.displayName) mode",
                    isError: true
                )
                break
            }
            let tool = ChatToolRegistry.shared.tool(named: block.name, in: mode)
            guard let tool else {
                result = ChatToolResult(content: "Tool '\(block.name)' is not registered", isError: true)
                break
            }
            do {
                result = try await tool.execute(input: block.input, context: context)
            } catch {
                result = ChatToolResult(content: "Error: \(error.localizedDescription)", isError: true)
            }
        case .cancelled:
            result = ChatToolResult(content: "User cancelled this tool call.", isError: true)
        case .denied(let reason):
            result = ChatToolResult(content: reason, isError: true)
        case .pending:
            result = ChatToolResult(content: "Tool approval was not resolved.", isError: true)
        }
        await replyToken.reply(result)
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
