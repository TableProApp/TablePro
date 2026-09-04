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
        assistantID: UUID,
        registry: ChatToolRegistry? = nil
    ) async -> [ToolUseBlock] {
        let initialBlocks = await MainActor.run { [weak self] () -> [ToolUseBlock] in
            guard let self else { return assembledBlocks }
            let initial = assembledBlocks.map { block -> ToolUseBlock in
                let state = self.computeInitialApprovalState(
                    for: block.name,
                    input: block.input,
                    registry: registry
                )
                return ToolUseBlock(
                    id: block.id,
                    name: block.name,
                    input: block.input,
                    approvalState: state,
                    providerMetadata: block.providerMetadata
                )
            }
            self.appendPendingToolUseBlocks(initial, assistantID: assistantID)
            return initial
        }

        /// Every waiting call registers its own continuation before any of them is awaited, so the
        /// reader can work through the cards in whatever order they like. Awaiting them one at a
        /// time meant only the first had a continuation registered: a click on the third card hit
        /// `resolve`'s missing-continuation guard and did nothing, while the stream stayed parked on
        /// the first. Registering up front also means the card the reader clicked repaints at once,
        /// because its own decision arrives and updates its block rather than waiting its turn.
        ///
        /// Execution order is untouched. Approvals are collected here; the statements themselves run
        /// afterwards, in transcript order, in `executeToolUses`.
        let session = sessionId
        let awaitedStates: [String: Task<ToolApprovalState, Never>] = await MainActor.run { [weak self] in
            var tasks: [String: Task<ToolApprovalState, Never>] = [:]
            for block in initialBlocks {
                guard case .pending = block.approvalState else { continue }
                let request = ApprovalRequestID(sessionId: session, toolUseId: block.id)
                tasks[block.id] = Task { @MainActor in
                    let decision = await ToolApprovalCenter.shared.awaitDecision(for: request)
                    let state: ToolApprovalState
                    switch decision {
                    case .run:
                        state = .approved
                    case .alwaysAllow:
                        self?.persistAlwaysAllowed(toolName: block.name)
                        state = .approved
                    case .cancel:
                        state = .cancelled
                    }
                    self?.updateApprovalState(blockID: block.id, newState: state, assistantID: assistantID)
                    return state
                }
            }
            return tasks
        }

        var resolved: [ToolUseBlock] = []
        for block in initialBlocks {
            guard let awaited = awaitedStates[block.id] else {
                resolved.append(block)
                continue
            }
            resolved.append(ToolUseBlock(
                id: block.id,
                name: block.name,
                input: block.input,
                approvalState: await awaited.value,
                providerMetadata: block.providerMetadata
            ))
        }
        return resolved
    }

    /// Whether a tool call waits for a human, and if not, why not.
    ///
    /// Evaluated against the connection the call **targets**, not against the session's own. Eight
    /// of the nine chat tools take `connection_id` as a model-fillable input, so the two are not
    /// always the same, and the level that matters is the one on the database being written to.
    /// A target outside this session is refused here as well as inside `resolveConnectionId`,
    /// because a read-only tool never reaches this function at all.
    ///
    /// Every arm without a connection now denies. It used to fall through `if let connection` and
    /// return `.pending`, and before that `.approved`: a send that landed before the panel's first
    /// layout had assigned `viewModel.connection` skipped the AI-access policy, the consent alert
    /// and every Safe Mode denial.
    @MainActor
    func computeInitialApprovalState(
        for toolName: String,
        input: JsonValue,
        registry: ChatToolRegistry? = nil
    ) -> ToolApprovalState {
        let resolvedRegistry = registry ?? ChatToolRegistry.shared
        let tool = resolvedRegistry.tool(named: toolName)
        let toolMode = tool?.mode

        /// A tool from an outside MCP server always waits for a human, in every chat mode, whatever
        /// mode it declares and whatever the connection's grants say. "Read-only" is the server's
        /// claim about itself, and what leaves the machine on such a call is the schema and the rows
        /// the assistant hands it. Checked ahead of every other arm, including the `.readOnly`
        /// shortcut a remote tool would otherwise take straight to `.approved`.
        if resolvedRegistry.isRemoteTool(named: toolName) {
            return .pending
        }

        if toolMode == .readOnly {
            return .approved
        }

        guard let sessionConnection = connection else {
            return .denied(reason: String(
                localized: "This chat session is not attached to a connection, so no tool that writes can run."
            ))
        }

        let target: DatabaseConnection
        switch resolveTargetConnection(input: input, sessionConnection: sessionConnection) {
        case .allowed(let resolved):
            target = resolved
        case .refused(let reason):
            return .denied(reason: reason)
        }

        let safeModeLevel = effectiveSafeModeLevel(for: target)

        /// Destructive operations (`.agentOnly`) always require user approval. Safe Mode level and
        /// "Always Allow" cannot bypass them: the AI must not be able to drop tables, truncate, or
        /// alter-drop without an explicit click.
        if toolMode == .agentOnly {
            if safeModeLevel.blocksAllWrites {
                return .denied(reason: String(
                    localized: "TablePro's Safe Mode is set to read-only for this connection. Destructive operations are not permitted."
                ))
            }
            return .pending
        }

        if safeModeLevel.blocksAllWrites {
            return .denied(reason: String(
                localized: "TablePro's Safe Mode is set to read-only for this connection. Set it to Confirm Writes or higher to allow this tool."
            ))
        }
        /// A grant cannot switch off a floor the user did not set. `execute_query` is the only
        /// `.write` tool in the registry, so "Always for this connection" on it means every
        /// non-destructive `INSERT`, `UPDATE` and `DELETE` on that connection, forever. Checked
        /// ahead of `requiresConfirmation`, one click undid the whole promise of the mode, and on a
        /// Silent connection the floor is the only thing that renders the card the button sits on:
        /// the mode created the button that turned the mode off.
        if !floorRaisedSafeModeLevel(for: target), target.aiAlwaysAllowedTools.contains(toolName) {
            return .approved
        }
        if !safeModeLevel.requiresConfirmation {
            return .approved
        }
        return .pending
    }

    /// The connection a call acts on. A session is pinned to one, so a target the model named that
    /// is not this session's is refused with a message the model can act on rather than silently
    /// retargeted.
    enum TargetResolution {
        case allowed(DatabaseConnection)
        case refused(String)
    }

    @MainActor
    private func resolveTargetConnection(
        input: JsonValue,
        sessionConnection: DatabaseConnection
    ) -> TargetResolution {
        guard let requested = try? ChatToolArgumentDecoder.requireUUID(input, key: "connection_id") else {
            return .allowed(sessionConnection)
        }
        guard requested == sessionConnection.id else {
            return .refused(String(
                format: String(
                    localized: "This session is attached to %@. Start a session on the other connection to work there."
                ),
                sessionConnection.name
            ))
        }
        return .allowed(sessionConnection)
    }

    /// The level the approval path acts on: the connection's live level, raised to Assistant mode's
    /// floor while that mode is on. A minimum, never a maximum, and nothing is written to storage,
    /// so leaving the mode is all it takes to have the user's own level back.
    @MainActor
    func effectiveSafeModeLevel(for connection: DatabaseConnection) -> SafeModeLevel {
        AssistantSafeModeFloor.effectiveLevel(
            live: liveSafeModeLevel(for: connection),
            connectionId: connection.id,
            store: contentModeStore
        )
    }

    /// Whether a floor rather than the user's own choice is what is asking for the confirmation.
    /// Read separately from the level so a grant made for their own level cannot switch off a floor
    /// an administrator or Assistant mode imposed.
    @MainActor
    func floorRaisedSafeModeLevel(for connection: DatabaseConnection) -> Bool {
        AssistantSafeModeFloor.floorRaisedLevel(
            live: liveSafeModeLevel(for: connection),
            connectionId: connection.id,
            store: contentModeStore
        )
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

    @MainActor
    /// Records a grant, or refuses to.
    ///
    /// Destructive operations are refused: each DROP, TRUNCATE and ALTER…DROP is confirmed on its
    /// own. A grant is also refused while a floor is what is asking for the confirmation, because
    /// `computeInitialApprovalState` ignores grants in that case: writing one would leave a
    /// permanent entry that does nothing now and quietly takes effect the moment the floor lifts.
    /// The click still runs this statement; it just does not become "always".
    ///
    /// The record is re-read from storage rather than taken from this view model's own copy. That
    /// copy is a snapshot, and `updateConnection` replaces the stored record wholesale and marks it
    /// dirty for iCloud, so pushing a snapshot here could roll back a Safe Mode level or an AI
    /// policy the user changed after the panel was created, and sync the rollback to their other
    /// Macs.
    func persistAlwaysAllowed(toolName: String) {
        if ChatToolRegistry.shared.tool(named: toolName)?.mode == .agentOnly {
            return
        }
        /// A remote tool is never granted. `computeInitialApprovalState` forces it to `.pending`
        /// whatever is recorded, so a grant here would be a permanent entry that does nothing and
        /// reads, in the connection form, as permission the user gave and TablePro ignores.
        if ChatToolRegistry.shared.isRemoteTool(named: toolName) {
            return
        }
        guard let target = connection else { return }
        guard !floorRaisedSafeModeLevel(for: target) else { return }
        guard var stored = services.connectionStorage.loadConnection(id: target.id) else { return }
        guard !stored.aiAlwaysAllowedTools.contains(toolName) else { return }
        stored.aiAlwaysAllowedTools.insert(toolName)
        connection = stored
        services.connectionStorage.updateConnection(stored)
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
        let initialState = computeInitialApprovalState(for: block.name, input: block.input)
        let pendingBlock = ToolUseBlock(
            id: block.id,
            name: block.name,
            input: block.input,
            approvalState: initialState,
            providerMetadata: block.providerMetadata
        )
        appendPendingToolUseBlocks([pendingBlock], assistantID: assistantID)

        let finalState: ToolApprovalState
        if case .pending = initialState {
            let request = ApprovalRequestID(sessionId: sessionId, toolUseId: block.id)
            let decision = await ToolApprovalCenter.shared.awaitDecision(for: request)
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
            let scope = ChatToolScope(sessionId: sessionId, connectionId: connection?.id, mode: mode)
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
