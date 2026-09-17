//
//  AIChatViewModel+ToolApproval.swift
//  TablePro
//

import Foundation
import os

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

    /// The blocks with their settled approval state, and which of them the user answered by hand.
    ///
    /// Provenance cannot be read back off `ToolApprovalState`: `.approved` is reached both by a
    /// click and by a standing grant, and only the click has shown the user this statement and this
    /// connection. It travels alongside the blocks because one `ChatToolContext` is built per
    /// streaming round and shared by every block in it.
    struct ResolvedToolApprovals {
        let blocks: [ToolUseBlock]
        let explicitlyApproved: Set<String>
    }

    func resolveAndAwaitApprovals(
        assembledBlocks: [ToolUseBlock],
        assistantID: UUID,
        registry: ChatToolRegistry? = nil
    ) async -> ResolvedToolApprovals {
        let initialBlocks = await MainActor.run { [weak self] () -> [ToolUseBlock] in
            guard let self else { return assembledBlocks }
            let initial = assembledBlocks.map { block -> ToolUseBlock in
                let state = self.computeInitialApprovalState(for: block.name, registry: registry)
                return ToolUseBlock(
                    id: block.id,
                    name: block.name,
                    input: block.input,
                    approvalState: state,
                    providerMetadata: block.providerMetadata
                )
            }
            self.appendPendingToolUseBlocks(initial, assistantID: assistantID)
            ToolApprovalCenter.shared.expect(
                initial.compactMap { block in
                    guard case .pending = block.approvalState else { return nil }
                    return block.id
                }
            )
            return initial
        }
        defer {
            let ids = initialBlocks.map(\.id)
            Task { @MainActor in ToolApprovalCenter.shared.forget(ids) }
        }

        var resolved: [ToolUseBlock] = []
        var explicitlyApproved: Set<String> = []
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
                explicitlyApproved.insert(block.id)
            case .alwaysAllow:
                await MainActor.run { [weak self] in
                    self?.persistAlwaysAllowed(toolName: block.name)
                }
                finalState = .approved
                explicitlyApproved.insert(block.id)
            case .cancel:
                finalState = .cancelled
            }
            await MainActor.run { [weak self] in
                self?.updateApprovalState(blockID: block.id, newState: finalState, assistantID: assistantID)
            }
            resolved.append(ToolUseBlock(
                id: block.id,
                name: block.name,
                input: block.input,
                approvalState: finalState,
                providerMetadata: block.providerMetadata
            ))
        }
        return ResolvedToolApprovals(blocks: resolved, explicitlyApproved: explicitlyApproved)
    }

    @MainActor
    func computeInitialApprovalState(
        for toolName: String,
        registry: ChatToolRegistry? = nil
    ) -> ToolApprovalState {
        let tool = (registry ?? ChatToolRegistry.shared).tool(named: toolName)
        let toolMode = tool?.mode

        if toolMode == .readOnly {
            return .approved
        }

        // Destructive operations (`.agentOnly`) always require user approval.
        // Safe-mode level and "Always Allow" cannot bypass them — the AI must not
        // be able to drop tables, truncate, or alter-drop without an explicit click.
        if toolMode == .agentOnly {
            if let connection, liveSafeModeLevel(for: connection).blocksAllWrites {
                return .denied(reason: String(
                    localized: "TablePro's Safe Mode is set to read-only for this connection. Destructive operations are not permitted."
                ))
            }
            return .pending
        }

        if let connection, connection.aiAlwaysAllowedTools.contains(toolName) {
            return .approved
        }
        if let connection {
            let safeModeLevel = liveSafeModeLevel(for: connection)
            if safeModeLevel.blocksAllWrites {
                return .denied(reason: String(
                    localized: "TablePro's Safe Mode is set to read-only for this connection. Set it to Confirm Writes or higher to allow this tool."
                ))
            }
            if !safeModeLevel.requiresConfirmation {
                return .approved
            }
        }
        return .pending
    }

    @MainActor
    private func liveSafeModeLevel(for connection: DatabaseConnection) -> SafeModeLevel {
        DatabaseManager.shared.session(for: connection.id)?.safeModeLevel ?? connection.safeModeLevel
    }

    @MainActor
    func appendPendingToolUseBlocks(_ blocks: [ToolUseBlock], assistantID: UUID) {
        guard let turn = turn(withID: assistantID) else { return }
        for block in blocks {
            turn.appendBlock(.toolUse(block))
        }
    }

    @MainActor
    func updateApprovalState(blockID: String, newState: ToolApprovalState, assistantID: UUID) {
        guard let turn = turn(withID: assistantID) else { return }
        for chatBlock in turn.blocks {
            if case .toolUse(var block) = chatBlock.kind, block.id == blockID {
                block.approvalState = newState
                chatBlock.setKind(.toolUse(block))
                return
            }
        }
    }

    /// Records an Always Allow grant as a read-modify-write of the one field it changes.
    ///
    /// It used to save the whole `DatabaseConnection` the view model was holding. That record is
    /// read once, in `AIChatPanelView`'s `onAppear` and again only when the connection's id changes,
    /// so a Safe Mode level raised in the toolbar while the pane stayed mounted was still the old
    /// one here, and the grant wrote it back and silently undid the change.
    ///
    /// A destructive operation is never granted: each DROP, TRUNCATE and ALTER...DROP is confirmed
    /// on its own.
    @MainActor
    func persistAlwaysAllowed(toolName: String) {
        if ChatToolRegistry.shared.tool(named: toolName)?.mode == .agentOnly {
            return
        }
        guard let connectionId = connection?.id else { return }
        guard connection?.aiAlwaysAllowedTools.contains(toolName) == false else { return }
        guard services.connectionStorage.mutateConnections(ids: [connectionId], { stored in
            stored.aiAlwaysAllowedTools.insert(toolName)
        }) else {
            Self.logger.error("Could not record Always Allow for \(toolName, privacy: .public)")
            return
        }
        connection?.aiAlwaysAllowedTools.insert(toolName)
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
            id: block.id,
            name: block.name,
            input: block.input,
            approvalState: initialState,
            providerMetadata: block.providerMetadata
        )
        appendPendingToolUseBlocks([pendingBlock], assistantID: assistantID)
        if case .pending = initialState {
            ToolApprovalCenter.shared.expect([block.id])
        }
        defer { ToolApprovalCenter.shared.forget([block.id]) }

        let finalState: ToolApprovalState
        var approvalWasExplicit = false
        if case .pending = initialState {
            let decision = await ToolApprovalCenter.shared.awaitDecision(for: block.id)
            switch decision {
            case .run:
                finalState = .approved
                approvalWasExplicit = true
            case .alwaysAllow:
                persistAlwaysAllowed(toolName: block.name)
                finalState = .approved
                approvalWasExplicit = true
            case .cancel:
                finalState = .cancelled
            }
            updateApprovalState(blockID: block.id, newState: finalState, assistantID: assistantID)
        } else {
            finalState = initialState
        }
        let callContext = context.carrying(approvalWasExplicit: approvalWasExplicit)

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
                result = try await tool.execute(input: block.input, context: callContext)
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
