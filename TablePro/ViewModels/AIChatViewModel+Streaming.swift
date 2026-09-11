//
//  AIChatViewModel+Streaming.swift
//  TablePro
//

import Foundation
import os
import SwiftUI
import TableProPluginKit

extension AIChatViewModel {
    static let hardToolRoundtripCeiling = 500

    struct ToolRoundtripContinuation {
        let nextAssistantID: UUID
        let assistantTurn: ChatTurnWire
        let userTurn: ChatTurnWire
    }

    private struct StreamRoundResult {
        let toolUseOrder: [String]
        let toolUseNames: [String: String]
        let toolUseInputs: [String: String]
        let toolUseMetadata: [String: [String: String]]
        let cancelled: Bool
    }

    private enum ToolResolution {
        case blocked
        case missing
        case resolved(any ChatTool)
    }

    func startStreaming() {
        switch streamingState {
        case .idle, .pausedAtToolLimit:
            break
        case .loading, .streaming, .awaitingApproval, .failed:
            return
        }

        let settings = services.appSettings.ai

        let resolved = AIProviderFactory.resolve(
            settings: settings,
            overrideProviderId: selectedProviderId,
            overrideModel: selectedModel
        )
        guard let resolved else {
            errorMessage = String(localized: "No AI provider configured. Go to Settings > AI to add one.")
            return
        }

        /// Fails closed. This used to read `if connection != nil`, so a send that landed before the
        /// panel's first layout had assigned the connection skipped the `.never` policy, the
        /// per-send consent alert, and every Safe Mode denial downstream. A session with no
        /// connection now refuses instead of streaming unchecked.
        guard connection != nil else {
            errorMessage = String(
                localized: "This chat session is not attached to a connection. Open a connection and try again."
            )
            if let last = messages.last, last.role == .user {
                messages.removeLast()
            }
            return
        }
        if let policy = resolveConnectionPolicy(settings: settings) {
            if policy == .never {
                errorMessage = String(localized: "AI is disabled for this connection.")
                if let last = messages.last, last.role == .user {
                    messages.removeLast()
                }
                return
            }
            if policy == .askEachTime {
                streamingState = .awaitingApproval
                showAIAccessConfirmation = true
                return
            }
        }

        beginStreamingTurn(
            resolved: resolved,
            settings: settings,
            includeWalkthroughDirective: pendingWalkthroughBeforeSQL != nil
        )
    }

    func continueToolLoop() {
        guard case .pausedAtToolLimit = streamingState else { return }

        let settings = services.appSettings.ai
        let resolved = AIProviderFactory.resolve(
            settings: settings,
            overrideProviderId: selectedProviderId,
            overrideModel: selectedModel
        )
        guard let resolved else {
            errorMessage = String(localized: "No AI provider configured. Go to Settings > AI to add one.")
            return
        }

        beginStreamingTurn(
            resolved: resolved,
            settings: settings,
            includeWalkthroughDirective: pendingWalkthroughBeforeSQL != nil
        )
    }

    private func beginStreamingTurn(
        resolved: AIProviderFactory.ResolvedProvider,
        settings: AISettings,
        includeWalkthroughDirective: Bool
    ) {
        let assistantMessage = ChatTurn(
            role: .assistant,
            blocks: [],
            modelId: resolved.model,
            providerId: resolved.config.id.uuidString
        )
        messages.append(assistantMessage)
        trimMessagesIfNeeded()
        let assistantID = assistantMessage.id
        streamingState = .streaming(assistantID: assistantID)

        prepTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            if settings.includeSchema {
                await self.ensureSchemaLoaded()
            }
            if Task.isCancelled { return }
            let priorTurns: [ChatTurn] = await MainActor.run {
                Array(self.messages.dropLast())
            }
            var chatMessages: [ChatTurnWire] = []
            for turn in priorTurns {
                if Task.isCancelled { return }
                chatMessages.append(await self.resolveTurnForWire(turn))
            }
            if Task.isCancelled { return }
            let promptContext: PromptContext? = await MainActor.run {
                self.capturePromptContext(settings: settings)
            }
            await MainActor.run {
                self.runStream(
                    chatMessages: chatMessages,
                    promptContext: promptContext,
                    resolved: resolved,
                    assistantID: assistantID,
                    settings: settings,
                    includeWalkthroughDirective: includeWalkthroughDirective
                )
                self.prepTask = nil
            }
        }
    }

    func runStream(
        chatMessages: [ChatTurnWire],
        promptContext: PromptContext?,
        resolved: AIProviderFactory.ResolvedProvider,
        assistantID: UUID,
        settings: AISettings,
        includeWalkthroughDirective: Bool = false,
        registry: ChatToolRegistry? = nil
    ) {
        let chatMode = self.chatMode
        let toolScope = ChatToolScope(sessionId: sessionId, connectionId: connection?.id, mode: chatMode)
        let leaseSessionId = sessionId
        let leaseConfigId = resolved.config.id
        let leaseProviderName = resolved.config.name
        let roundtripLimit = min(
            settings.effectiveMaxToolRoundtrips ?? Self.hardToolRoundtripCeiling,
            Self.hardToolRoundtripCeiling
        )
        streamingTask = Task.detached(priority: .userInitiated) { [weak self] in
            var currentAssistantID = assistantID
            await MainActor.run { [weak self] in
                guard let holder = ProviderStreamLease.shared.holdingSession(configId: leaseConfigId),
                      holder != leaseSessionId
                else { return }
                self?.providerWaitReason = ProviderStreamLease.waitMessage(providerName: leaseProviderName)
            }
            await ProviderStreamLease.shared.acquire(configId: leaseConfigId, sessionId: leaseSessionId)
            await MainActor.run { [weak self] in
                self?.providerWaitReason = nil
            }
            defer {
                Task { @MainActor in
                    ProviderStreamLease.shared.release(configId: leaseConfigId, sessionId: leaseSessionId)
                }
            }
            if Task.isCancelled { return }
            do {
                let systemPrompt = Self.buildSystemPrompt(
                    promptContext,
                    mode: chatMode,
                    includeWalkthroughDirective: includeWalkthroughDirective
                )
                guard let self else { return }
                let preflightOK = await self.preflightCheck(
                    systemPrompt: systemPrompt,
                    turns: chatMessages,
                    assistantID: assistantID
                )
                guard preflightOK else { return }

                let toolSpecs = await MainActor.run {
                    (registry ?? ChatToolRegistry.shared).specs(in: toolScope)
                }
                var workingTurns = chatMessages
                var executedRoundtrips = 0

                while true {
                    if executedRoundtrips >= roundtripLimit {
                        await self.pauseAtToolLimit(
                            assistantID: currentAssistantID,
                            count: executedRoundtrips
                        )
                        return
                    }

                    let round = try await self.consumeStreamRound(
                        resolved: resolved,
                        systemPrompt: systemPrompt,
                        toolSpecs: toolSpecs,
                        workingTurns: workingTurns,
                        assistantID: currentAssistantID,
                        chatMode: chatMode
                    )
                    if round.cancelled { return }
                    if round.toolUseOrder.isEmpty { break }

                    let assembled = Self.assembleToolUseBlocks(
                        order: round.toolUseOrder,
                        names: round.toolUseNames,
                        inputs: round.toolUseInputs,
                        metadata: round.toolUseMetadata
                    )
                    let context = await MainActor.run {
                        ChatToolContext(
                            connectionId: self.connection?.id,
                            bridge: ChatToolBootstrap.bridge,
                            authPolicy: ChatToolBootstrap.authPolicy,
                            sessionId: self.sessionId
                        )
                    }
                    let toolUseBlocks = await self.resolveAndAwaitApprovals(
                        assembledBlocks: assembled,
                        assistantID: currentAssistantID,
                        registry: registry
                    )
                    guard !Task.isCancelled else { return }

                    let approvedBlocks = toolUseBlocks.filter {
                        if case .approved = $0.approvalState { return true }
                        return false
                    }
                    let executedResults = await Self.executeToolUses(
                        approvedBlocks, scope: toolScope, context: context, registry: registry
                    )
                    guard !Task.isCancelled else { return }

                    let toolResultBlocks = Self.synthesizeResults(
                        for: toolUseBlocks,
                        executed: executedResults
                    )
                    let continuation = await self.completeToolRoundtrip(
                        assistantIDForRound: currentAssistantID,
                        toolUseBlocks: toolUseBlocks,
                        toolResultBlocks: toolResultBlocks,
                        resolved: resolved
                    )
                    currentAssistantID = continuation.nextAssistantID
                    workingTurns.append(continuation.assistantTurn)
                    workingTurns.append(continuation.userTurn)
                    executedRoundtrips += 1
                }

                guard !Task.isCancelled else { return }
                let finalAssistantID = currentAssistantID
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.finalizeStreamingMessage(id: finalAssistantID)
                    self.resolveWalkthroughIfNeeded(id: finalAssistantID)
                    self.streamingState = .idle
                    self.streamingTask = nil
                    self.persistCurrentConversation()
                }
            } catch {
                let failedAssistantID = currentAssistantID
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.pendingWalkthroughBeforeSQL = nil
                    if !Task.isCancelled {
                        Self.logger.error("Streaming failed: \(error.localizedDescription)")
                        self.errorMessage = error.localizedDescription
                        self.streamingState = .failed(error as? AIProviderError)
                        self.finalizeStreamingMessage(id: failedAssistantID)
                        if let idx = self.messages.firstIndex(where: { $0.id == failedAssistantID }),
                           self.messages[idx].blocks.isEmpty {
                            self.messages.remove(at: idx)
                        }
                    } else {
                        self.finalizeStreamingMessage(id: failedAssistantID)
                        self.streamingState = .idle
                    }
                    self.streamingTask = nil
                }
            }
        }
    }

    @MainActor
    func finalizeStreamingMessage(id: UUID) {
        turn(withID: id)?.finishStreamingTextBlock()
    }

    @MainActor
    func resolveWalkthroughIfNeeded(id: UUID) {
        guard let beforeSQL = pendingWalkthroughBeforeSQL else { return }
        pendingWalkthroughBeforeSQL = nil
        guard let turn = turn(withID: id) else { return }

        let textBlocks = turn.blocks.filter { block in
            if case .text = block.kind { return true }
            return false
        }
        guard let openOffset = textBlocks.firstIndex(where: { block in
            if case .text(let text) = block.kind {
                return text.contains(WalkthroughEnvelopeParser.openFence)
            }
            return false
        }) else { return }

        // A provider can split the envelope across text blocks, so parse the joined tail
        // rather than only the block that happens to carry the opening fence.
        let tail = Array(textBlocks[openOffset...])
        let joined = tail.compactMap { block -> String? in
            if case .text(let text) = block.kind { return text }
            return nil
        }.joined()

        guard case .text(let openText) = tail[0].kind else { return }
        let prose = WalkthroughEnvelopeParser.stripFence(from: openText)
        let consumedIDs = Set(tail.dropFirst().map(\.id))
        turn.blocks.removeAll { consumedIDs.contains($0.id) }

        if prose.isEmpty {
            turn.blocks.removeAll { $0.id == tail[0].id }
        } else {
            tail[0].setKind(.text(prose))
        }

        guard let envelope = WalkthroughEnvelopeParser.parse(from: joined) else { return }
        let walkthrough = SqlWalkthroughBlock(beforeSQL: beforeSQL, envelope: envelope)
        turn.appendBlock(.sqlWalkthrough(walkthrough))
    }

    private func consumeStreamRound(
        resolved: AIProviderFactory.ResolvedProvider,
        systemPrompt: String?,
        toolSpecs: [ChatToolSpec],
        workingTurns: [ChatTurnWire],
        assistantID: UUID,
        chatMode: AIChatMode
    ) async throws -> StreamRoundResult {
        let stream = resolved.provider.streamChat(
            turns: workingTurns,
            options: ChatTransportOptions(
                model: resolved.model,
                systemPrompt: systemPrompt,
                tools: toolSpecs,
                reasoningEffort: resolved.config.reasoningEffort,
                sessionId: sessionId
            )
        )

        let buffer = StreamTextBuffer()
        let reasoningIDMap = ReasoningBlockIDMap()
        let ticker = startFlushTicker(buffer: buffer, assistantID: assistantID, idMap: reasoningIDMap)
        defer {
            ticker.cancel()
            if !Task.isCancelled {
                drainBuffer(buffer, assistantID: assistantID, idMap: reasoningIDMap)
            }
        }

        return try await runProducerLoop(
            stream: stream,
            buffer: buffer,
            reasoningIDMap: reasoningIDMap,
            assistantID: assistantID,
            chatMode: chatMode
        )
    }

    private func startFlushTicker(
        buffer: StreamTextBuffer,
        assistantID: UUID,
        idMap: ReasoningBlockIDMap
    ) -> Task<Void, Never> {
        let clock = streamFlushClock
        let interval = streamFlushInterval
        return Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.drainBuffer(buffer, assistantID: assistantID, idMap: idMap)
            }
        }
    }

    @MainActor
    private func drainBuffer(_ buffer: StreamTextBuffer, assistantID: UUID, idMap: ReasoningBlockIDMap) {
        drainBufferedText(buffer, assistantID: assistantID)
        drainBufferedReasoning(buffer, assistantID: assistantID, idMap: idMap)
    }

    @MainActor
    private func drainBufferedText(_ buffer: StreamTextBuffer, assistantID: UUID) {
        guard buffer.hasBufferedText else { return }
        let drained = buffer.drainText()
        guard let turn = turn(withID: assistantID) else { return }
        if !drained.text.isEmpty {
            turn.appendStreamingToken(drained.text)
        }
        if let usage = drained.usage {
            turn.usage = usage
        }
    }

    @MainActor
    private func drainBufferedReasoning(
        _ buffer: StreamTextBuffer,
        assistantID: UUID,
        idMap: ReasoningBlockIDMap
    ) {
        guard buffer.hasBufferedReasoning, let turn = turn(withID: assistantID) else { return }
        for chunk in buffer.drainReasoning() {
            turn.appendReasoningDelta(
                providerBlockID: chunk.providerBlockID,
                text: chunk.text,
                idMap: &idMap.value
            )
        }
    }

    private func runProducerLoop(
        stream: AsyncThrowingStream<ChatStreamEvent, Error>,
        buffer: StreamTextBuffer,
        reasoningIDMap: ReasoningBlockIDMap,
        assistantID: UUID,
        chatMode: AIChatMode
    ) async throws -> StreamRoundResult {
        var toolUseOrder: [String] = []
        var toolUseNames: [String: String] = [:]
        var toolUseInputs: [String: String] = [:]
        var toolUseMetadata: [String: [String: String]] = [:]
        var hasRenderedFirstText = false

        for try await event in stream {
            guard !Task.isCancelled else { break }
            switch event {
            case .textDelta(let token):
                drainBufferedReasoning(buffer, assistantID: assistantID, idMap: reasoningIDMap)
                buffer.appendText(token)
                if !hasRenderedFirstText, buffer.hasBufferedText {
                    hasRenderedFirstText = true
                    drainBufferedText(buffer, assistantID: assistantID)
                }
            case .usage(let usage):
                buffer.setUsage(usage)
            case .toolUseStart(let id, let name, let providerMetadata):
                drainBuffer(buffer, assistantID: assistantID, idMap: reasoningIDMap)
                finalizeStreamingMessage(id: assistantID)
                if toolUseInputs[id] == nil {
                    toolUseOrder.append(id)
                    toolUseInputs[id] = ""
                }
                toolUseNames[id] = name
                if let providerMetadata, !providerMetadata.isEmpty {
                    toolUseMetadata[id] = providerMetadata
                }
            case .toolUseDelta(let id, let inputJSONDelta):
                toolUseInputs[id, default: ""] += inputJSONDelta
            case .toolUseEnd:
                break
            case .toolInvocationRequest(let block, let replyToken):
                drainBuffer(buffer, assistantID: assistantID, idMap: reasoningIDMap)
                await dispatchCopilotInvocation(
                    block: block, replyToken: replyToken,
                    assistantID: assistantID, mode: chatMode
                )
            case .reasoningStart(let providerID):
                drainBuffer(buffer, assistantID: assistantID, idMap: reasoningIDMap)
                turn(withID: assistantID)?
                    .startReasoningBlock(providerBlockID: providerID, idMap: &reasoningIDMap.value)
            case .reasoningDelta(let providerID, let text):
                drainBufferedText(buffer, assistantID: assistantID)
                buffer.appendReasoning(providerBlockID: providerID, text: text)
            case .reasoningEnd(let providerID, let opaque):
                drainBuffer(buffer, assistantID: assistantID, idMap: reasoningIDMap)
                turn(withID: assistantID)?.finalizeReasoningBlock(
                    providerBlockID: providerID,
                    opaque: opaque,
                    idMap: &reasoningIDMap.value
                )
            }
        }

        return StreamRoundResult(
            toolUseOrder: toolUseOrder,
            toolUseNames: toolUseNames,
            toolUseInputs: toolUseInputs,
            toolUseMetadata: toolUseMetadata,
            cancelled: Task.isCancelled
        )
    }

    nonisolated static func buildSystemPrompt(
        _ promptContext: PromptContext?,
        mode: AIChatMode,
        includeWalkthroughDirective: Bool = false
    ) -> String? {
        let schemaPrompt = promptContext.map {
            AISchemaContext.buildSystemPrompt(
                databaseType: $0.databaseType,
                databaseName: $0.databaseName,
                tables: $0.tables,
                columnsByTable: $0.columnsByTable,
                foreignKeys: $0.foreignKeys,
                currentQuery: $0.currentQuery,
                queryResults: $0.queryResults,
                settings: $0.settings,
                identifierQuote: $0.identifierQuote,
                editorLanguage: $0.editorLanguage,
                queryLanguageName: $0.queryLanguageName,
                connectionRules: $0.connectionRules
            )
        }
        let modeNote = mode.systemPromptNote
        let base: String?
        if let schemaPrompt, !schemaPrompt.isEmpty {
            base = "\(schemaPrompt)\n\n\(modeNote)"
        } else {
            base = modeNote
        }
        guard includeWalkthroughDirective else { return base }
        let directive = AIPromptTemplates.walkthroughSystemDirective
        guard let base, !base.isEmpty else { return directive }
        return "\(base)\n\n\(directive)"
    }

    private func pauseAtToolLimit(assistantID: UUID, count: Int) async {
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.finalizeStreamingMessage(id: assistantID)
            if let idx = self.messages.firstIndex(where: { $0.id == assistantID }),
               self.messages[idx].blocks.isEmpty {
                self.messages.remove(at: idx)
            }
            self.streamingState = .pausedAtToolLimit(count: count)
            self.streamingTask = nil
            self.persistCurrentConversation()
            AccessibilityNotification.Announcement(
                String(format: String(localized: "Paused after %d tool calls."), count)
            ).post()
        }
    }

    func completeToolRoundtrip(
        assistantIDForRound: UUID,
        toolUseBlocks: [ToolUseBlock],
        toolResultBlocks: [ToolResultBlock],
        resolved: AIProviderFactory.ResolvedProvider
    ) async -> ToolRoundtripContinuation {
        await MainActor.run { [weak self] () -> ToolRoundtripContinuation in
            self?.finalizeStreamingMessage(id: assistantIDForRound)
            let assistantWire: ChatTurnWire = {
                guard let self,
                      let idx = self.messages.firstIndex(where: { $0.id == assistantIDForRound })
                else {
                    return ChatTurnWire(
                        id: assistantIDForRound,
                        role: .assistant,
                        blocks: [],
                        modelId: resolved.model,
                        providerId: resolved.config.id.uuidString
                    )
                }
                return self.messages[idx].wireSnapshot
            }()
            let userTurn = ChatTurnWire(
                role: .user,
                blocks: toolResultBlocks.map { .toolResult($0) }
            )
            let nextAssistant = ChatTurn(
                role: .assistant,
                blocks: [],
                modelId: resolved.model,
                providerId: resolved.config.id.uuidString
            )
            let nextAssistantID = nextAssistant.id
            self?.messages.append(ChatTurn(wire: userTurn))
            self?.messages.append(nextAssistant)
            self?.streamingState = .streaming(assistantID: nextAssistantID)
            return ToolRoundtripContinuation(
                nextAssistantID: nextAssistantID,
                assistantTurn: assistantWire,
                userTurn: userTurn
            )
        }
    }

    func preflightCheck(systemPrompt: String?, turns: [ChatTurnWire], assistantID: UUID) async -> Bool {
        let totalSize = ((systemPrompt ?? "") as NSString).length
            + turns.reduce(0) { $0 + ($1.plainText as NSString).length }
        guard totalSize > 100_000 else { return true }
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.errorMessage = String(
                localized: "Message too large. Try disabling 'Include schema' or 'Include query results' in AI settings."
            )
            if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                self.messages.remove(at: idx)
            }
            self.streamingState = .idle
        }
        return false
    }

    nonisolated static func assembleToolUseBlocks(
        order: [String],
        names: [String: String],
        inputs: [String: String],
        metadata: [String: [String: String]] = [:]
    ) -> [ToolUseBlock] {
        order.compactMap { id -> ToolUseBlock? in
            guard let name = names[id] else { return nil }
            let inputString = inputs[id] ?? "{}"
            let inputValue: JsonValue
            if inputString.isEmpty {
                inputValue = .object([:])
            } else if let data = inputString.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(JsonValue.self, from: data) {
                inputValue = decoded
            } else {
                inputValue = .object([:])
            }
            return ToolUseBlock(
                id: id,
                name: name,
                input: inputValue,
                providerMetadata: metadata[id]
            )
        }
    }

    nonisolated static func executeToolUses(
        _ blocks: [ToolUseBlock],
        scope: ChatToolScope,
        context: ChatToolContext,
        registry: ChatToolRegistry? = nil
    ) async -> [ToolResultBlock] {
        await withTaskGroup(of: (Int, ToolResultBlock).self) { group in
            for (index, block) in blocks.enumerated() {
                group.addTask {
                    (index, await runToolUse(block, scope: scope, context: context, registry: registry))
                }
            }
            var indexed: [(Int, ToolResultBlock)] = []
            for await pair in group { indexed.append(pair) }
            return indexed.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
    }

    nonisolated private static func runToolUse(
        _ block: ToolUseBlock,
        scope: ChatToolScope,
        context: ChatToolContext,
        registry: ChatToolRegistry?
    ) async -> ToolResultBlock {
        if Task.isCancelled {
            return ToolResultBlock(toolUseId: block.id, content: "Cancelled", isError: true)
        }
        let resolution = await MainActor.run { () -> ToolResolution in
            let activeRegistry = registry ?? ChatToolRegistry.shared
            guard activeRegistry.isToolAllowed(name: block.name, in: scope) else {
                return .blocked
            }
            guard let tool = activeRegistry.tool(named: block.name, in: scope) else {
                return .missing
            }
            return .resolved(tool)
        }
        let tool: any ChatTool
        switch resolution {
        case .blocked:
            AIChatViewModel.logger.warning(
                "Tool '\(block.name, privacy: .public)' blocked in \(scope.mode.rawValue, privacy: .public) mode"
            )
            return ToolResultBlock(
                toolUseId: block.id,
                content: "Tool '\(block.name)' is not available in \(scope.mode.displayName) mode",
                isError: true
            )
        case .missing:
            AIChatViewModel.logger.warning("Tool '\(block.name, privacy: .public)' not registered; returning error")
            return ToolResultBlock(
                toolUseId: block.id,
                content: "Tool '\(block.name)' is not available",
                isError: true
            )
        case .resolved(let resolved):
            tool = resolved
        }
        do {
            let result = try await tool.execute(input: block.input, context: context)
            return ToolResultBlock(
                toolUseId: block.id,
                content: result.content,
                isError: result.isError
            )
        } catch {
            AIChatViewModel.logger.warning(
                "Tool \(block.name, privacy: .public) execution failed: \(error.localizedDescription, privacy: .public)"
            )
            return ToolResultBlock(
                toolUseId: block.id,
                content: "Error: \(error.localizedDescription)",
                isError: true
            )
        }
    }
}
