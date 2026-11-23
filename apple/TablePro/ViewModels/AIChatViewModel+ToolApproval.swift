//
//  AIChatViewModel+ToolApproval.swift
//  TablePro
//

import Foundation
import os

extension AIChatViewModel {
    func confirmAIAccess() {
        if let connectionID = connection?.id {
            services.aiAccessApprovals.approve(connectionID)
        }
        guard case .awaitingApproval = streamingState else { return }
        streamingState = .idle
        startStreaming()
    }

    func denyAIAccess() {
        guard case .awaitingApproval = streamingState else { return }
        streamingState = .idle
        clearPendingWalkthrough()
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
                let state: ToolApprovalState
                if case .denied = block.approvalState {
                    state = block.approvalState
                } else {
                    state = self.computeInitialApprovalState(for: block.name, registry: registry)
                }
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
                sessionId: self.sessionId,
                toolUseIds: initial.compactMap { block in
                    guard case .pending = block.approvalState else { return nil }
                    return block.id
                }
            )
            return initial
        }
        let sessionId = await MainActor.run { self.sessionId }
        defer {
            let ids = initialBlocks.map(\.id)
            Task { @MainActor in
                ToolApprovalCenter.shared.forget(sessionId: sessionId, toolUseIds: ids)
            }
        }

        var resolved: [ToolUseBlock] = []
        var explicitlyApproved: Set<String> = []
        for block in initialBlocks {
            guard case .pending = block.approvalState else {
                resolved.append(block)
                continue
            }
            let decision = await ToolApprovalCenter.shared.awaitDecision(
                sessionId: sessionId,
                toolUseId: block.id
            )
            let decidedState: ToolApprovalState
            switch decision {
            case .run:
                decidedState = .approved
            case .alwaysAllow:
                await MainActor.run { [weak self] in
                    self?.persistAlwaysAllowed(toolName: block.name)
                }
                decidedState = .approved
            case .cancel:
                decidedState = .cancelled
            }
            let finalState = await MainActor.run { [weak self] in
                self?.updateApprovalState(blockID: block.id, newState: decidedState, assistantID: assistantID)
                    ?? .cancelled
            }
            if case .approved = finalState {
                explicitlyApproved.insert(block.id)
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
        let activeRegistry = registry ?? ChatToolRegistry.shared
        let tool = activeRegistry.tool(named: toolName)
        let toolMode = tool?.mode

        /// A call to an outside MCP server always waits for a human, whatever the server declared
        /// about itself. "Read-only" in a remote tool's own listing is that server's claim about its
        /// own behaviour, and it is not a claim TablePro is in any position to check; the arguments
        /// leave this machine either way. `aiAlwaysAllowedTools` cannot pre-clear one either, for
        /// the same reason a destructive statement cannot.
        if activeRegistry.isRemoteTool(named: toolName) {
            return .pending
        }

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

        // Read-Only comes first: an Always Allow grant is consent to the tool, not to a level that refuses writes.
        if let connection, liveSafeModeLevel(for: connection).blocksAllWrites {
            guard let level = SafeModeFloor.levelThatWrites(above: AgentModeSafeModeFloor.effectiveFloor(for: connection)?.level)
            else {
                return .denied(reason: String(
                    localized: "TablePro's Safe Mode is held at Read-Only for this connection, so this tool cannot run."
                ))
            }
            return .denied(reason: String(
                format: String(
                    localized: "TablePro's Safe Mode is set to Read-Only for this connection. Switch it to %@ to allow this tool."
                ),
                level.displayName
            ))
        }
        if let connection, alwaysAllowedTools(for: connection).contains(toolName) {
            return .approved
        }
        if let connection, !liveSafeModeLevel(for: connection).requiresConfirmation {
            return .approved
        }
        return .pending
    }

    @MainActor
    private func liveSafeModeLevel(for connection: DatabaseConnection) -> SafeModeLevel {
        DatabaseManager.shared.session(for: connection.id)?.safeModeLevel ?? connection.safeModeLevel
    }

    // `connection` is read once per pane, so a grant forgotten in the form or changed by sync after
    // that is only in storage.
    @MainActor
    private func alwaysAllowedTools(for connection: DatabaseConnection) -> Set<String> {
        services.connectionStorage.loadConnection(id: connection.id)?.aiAlwaysAllowedTools
            ?? connection.aiAlwaysAllowedTools
    }

    @MainActor
    func appendPendingToolUseBlocks(_ blocks: [ToolUseBlock], assistantID: UUID) {
        guard let turn = turn(withID: assistantID) else { return }
        for block in blocks {
            turn.appendBlock(.toolUse(block))
        }
    }

    // Returns the state the card holds afterwards. Stop settles a card before a Run click already
    // in flight lands, and New Conversation or a switch drops its turn: either way nothing runs.
    @MainActor
    @discardableResult
    func updateApprovalState(blockID: String, newState: ToolApprovalState, assistantID: UUID) -> ToolApprovalState {
        guard let turn = turn(withID: assistantID) else { return .cancelled }
        for chatBlock in turn.blocks {
            if case .toolUse(var block) = chatBlock.kind, block.id == blockID {
                if case .cancelled = block.approvalState { return .cancelled }
                block.approvalState = newState
                chatBlock.setKind(.toolUse(block))
                return newState
            }
        }
        return .cancelled
    }

    // The task marks a stopped card only after a hop back to the main actor, by which time the
    // transcript has been saved or replaced.
    @MainActor
    func settlePendingToolApprovals() {
        for turn in messages {
            for block in turn.blocks {
                guard case .toolUse(var use) = block.kind, case .pending = use.approvalState else { continue }
                use.approvalState = .cancelled
                block.setKind(.toolUse(use))
            }
        }
    }

    // Writes only this field: the view model's copy of the connection can be stale. A destructive
    // or remote tool is never granted.
    @MainActor
    func persistAlwaysAllowed(toolName: String) {
        if ChatToolRegistry.shared.tool(named: toolName)?.mode == .agentOnly {
            return
        }
        if ChatToolRegistry.shared.isRemoteTool(named: toolName) {
            return
        }
        guard let connectionId = connection?.id else { return }
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
            authPolicy: ChatToolBootstrap.authPolicy,
            chatMode: mode,
            sessionId: sessionId
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
            ToolApprovalCenter.shared.expect(sessionId: sessionId, toolUseIds: [block.id])
        }
        defer { ToolApprovalCenter.shared.forget(sessionId: sessionId, toolUseIds: [block.id]) }

        let finalState: ToolApprovalState
        var approvalWasExplicit = false
        if case .pending = initialState {
            let decision = await ToolApprovalCenter.shared.awaitDecision(
                sessionId: sessionId,
                toolUseId: block.id
            )
            let decidedState: ToolApprovalState
            switch decision {
            case .run:
                decidedState = .approved
            case .alwaysAllow:
                persistAlwaysAllowed(toolName: block.name)
                decidedState = .approved
            case .cancel:
                decidedState = .cancelled
            }
            finalState = updateApprovalState(blockID: block.id, newState: decidedState, assistantID: assistantID)
            if case .approved = finalState {
                approvalWasExplicit = true
            }
        } else {
            finalState = initialState
        }
        let callContext = context.carrying(approvalWasExplicit: approvalWasExplicit)

        let scope = ChatToolScope(sessionId: sessionId, connectionId: connection?.id, mode: mode)
        let result: ChatToolResult
        switch finalState {
        case .approved:
            guard ChatToolRegistry.shared.isToolAllowed(name: block.name, in: scope) else {
                result = ChatToolResult(
                    content: "Tool '\(block.name)' is not available in \(mode.displayName) mode",
                    isError: true
                )
                break
            }
            let tool = ChatToolRegistry.shared.tool(named: block.name, in: scope)
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
        appendToolResultBlock(
            ToolResultBlock(toolUseId: block.id, content: result.content, isError: result.isError),
            assistantID: assistantID
        )
        await replyToken.reply(result)
    }

    /// Writes a Copilot call's outcome into the transcript beside the call itself.
    ///
    /// Every other provider records one because the next round has to send it back. Copilot keeps
    /// the conversation on its own server and is answered over the LSP request instead, so nothing
    /// forced the block to exist and the transcript held a call with no outcome: the result pane
    /// read every statement as still waiting, and a restored session lost what had already run.
    @MainActor
    func appendToolResultBlock(_ result: ToolResultBlock, assistantID: UUID) {
        guard let turn = turn(withID: assistantID) else { return }
        turn.appendBlock(.toolResult(result))
    }

    /// Pairs each proposed call with its outcome by position, not by id.
    ///
    /// `executeToolUses` returns one result per approved block in the order it was given them, so
    /// position is exact. An id-keyed dictionary is not: several endpoints number a turn's calls
    /// from `call_0` and a provider is free to repeat one inside a round, which made
    /// `Dictionary(uniqueKeysWithValues:)` trap on the duplicate key.
    nonisolated static func synthesizeResults(
        for blocks: [ToolUseBlock],
        executed: [ToolResultBlock]
    ) -> [ToolResultBlock] {
        var remaining = executed[...]
        return blocks.map { block in
            switch block.approvalState {
            case .approved:
                return remaining.popFirst() ?? ToolResultBlock(
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
