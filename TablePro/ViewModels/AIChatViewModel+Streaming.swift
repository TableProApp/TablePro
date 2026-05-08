//
//  AIChatViewModel+Streaming.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

extension AIChatViewModel {
    static let maxToolRoundtrips = 10

    struct ToolRoundtripContinuation {
        let nextAssistantID: UUID
        let assistantTurn: ChatTurn
        let userTurn: ChatTurn
    }

    private struct StreamRoundResult {
        let toolUseOrder: [String]
        let toolUseNames: [String: String]
        let toolUseInputs: [String: String]
        let cancelled: Bool
    }

    func startStreaming() {
        guard case .idle = streamingState else { return }

        let settings = AppSettingsManager.shared.ai

        let resolved = AIProviderFactory.resolve(
            settings: settings,
            overrideProviderId: selectedProviderId,
            overrideModel: selectedModel
        )
        guard let resolved else {
            errorMessage = String(localized: "No AI provider configured. Go to Settings > AI to add one.")
            return
        }

        if connection != nil, let policy = resolveConnectionPolicy(settings: settings) {
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

        prepTask = Task { [weak self] in
            guard let self else { return }
            if settings.includeSchema {
                await self.ensureSchemaLoaded()
            }
            guard !Task.isCancelled else { return }
            let promptContext = self.capturePromptContext(settings: settings)
            var chatMessages: [ChatTurn] = []
            for turn in self.messages.dropLast() {
                chatMessages.append(await self.resolveTurnForWire(turn))
            }
            guard !Task.isCancelled else { return }
            self.runStream(
                chatMessages: chatMessages,
                promptContext: promptContext,
                resolved: resolved,
                assistantID: assistantID,
                settings: settings
            )
            self.prepTask = nil
        }
    }

    func runStream(
        chatMessages: [ChatTurn],
        promptContext: PromptContext?,
        resolved: AIProviderFactory.ResolvedProvider,
        assistantID: UUID,
        settings: AISettings
    ) {
        let chatMode = settings.chatMode
        streamingTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let systemPrompt = Self.buildSystemPrompt(promptContext, mode: chatMode)
                guard let self else { return }
                let preflightOK = await self.preflightCheck(
                    systemPrompt: systemPrompt,
                    turns: chatMessages,
                    assistantID: assistantID
                )
                guard preflightOK else { return }

                let toolSpecs = await MainActor.run { ChatToolRegistry.shared.allSpecs(for: chatMode) }
                var workingTurns = chatMessages
                var currentAssistantID = assistantID

                for roundtrip in 0..<Self.maxToolRoundtrips {
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

                    if roundtrip == Self.maxToolRoundtrips - 1 {
                        await self.failTooManyRoundtrips(assistantID: currentAssistantID)
                        break
                    }

                    let assembled = Self.assembleToolUseBlocks(
                        order: round.toolUseOrder,
                        names: round.toolUseNames,
                        inputs: round.toolUseInputs
                    )
                    let context = await MainActor.run {
                        ChatToolContext(
                            connectionId: self.connection?.id,
                            bridge: ChatToolBootstrap.bridge,
                            authPolicy: ChatToolBootstrap.authPolicy
                        )
                    }
                    let toolUseBlocks = await self.resolveAndAwaitApprovals(
                        assembledBlocks: assembled,
                        assistantID: currentAssistantID
                    )
                    guard !Task.isCancelled else { return }

                    let approvedBlocks = toolUseBlocks.filter {
                        if case .approved = $0.approvalState { return true }
                        return false
                    }
                    let executedResults = await Self.executeToolUses(
                        approvedBlocks, mode: chatMode, context: context
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
                }

                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.streamingState = .idle
                    self.streamingTask = nil
                    self.persistCurrentConversation()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if !Task.isCancelled {
                        Self.logger.error("Streaming failed: \(error.localizedDescription)")
                        self.errorMessage = error.localizedDescription
                        self.streamingState = .failed(error as? AIProviderError)

                        if let idx = self.messages.firstIndex(where: { $0.id == assistantID }),
                           self.messages[idx].plainText.isEmpty {
                            self.messages.remove(at: idx)
                        }
                    } else {
                        self.streamingState = .idle
                    }
                    self.streamingTask = nil
                }
            }
        }
    }

    private func consumeStreamRound(
        resolved: AIProviderFactory.ResolvedProvider,
        systemPrompt: String?,
        toolSpecs: [ChatToolSpec],
        workingTurns: [ChatTurn],
        assistantID: UUID,
        chatMode: AIChatMode
    ) async throws -> StreamRoundResult {
        let stream = resolved.provider.streamChat(
            turns: workingTurns,
            options: ChatTransportOptions(
                model: resolved.model,
                systemPrompt: systemPrompt,
                tools: toolSpecs
            )
        )

        var pendingContent = ""
        var pendingUsage: AITokenUsage?
        var toolUseOrder: [String] = []
        var toolUseNames: [String: String] = [:]
        var toolUseInputs: [String: String] = [:]
        let flushInterval: ContinuousClock.Duration = .milliseconds(150)
        var lastFlushTime: ContinuousClock.Instant = .now

        for try await event in stream {
            guard !Task.isCancelled else { break }
            switch event {
            case .textDelta(let token):
                pendingContent += token
            case .usage(let usage):
                pendingUsage = usage
            case .toolUseStart(let id, let name):
                if toolUseInputs[id] == nil {
                    toolUseOrder.append(id)
                    toolUseInputs[id] = ""
                }
                toolUseNames[id] = name
            case .toolUseDelta(let id, let inputJSONDelta):
                toolUseInputs[id, default: ""] += inputJSONDelta
            case .toolUseEnd:
                break
            case .toolInvocationRequest(let block, let replyToken):
                await self.dispatchCopilotInvocation(
                    block: block, replyToken: replyToken,
                    assistantID: assistantID, mode: chatMode
                )
            }

            if ContinuousClock.now - lastFlushTime >= flushInterval {
                await self.flushPending(content: pendingContent, usage: pendingUsage, into: assistantID)
                pendingContent = ""
                pendingUsage = nil
                lastFlushTime = .now
            }
        }

        if !Task.isCancelled, !pendingContent.isEmpty || pendingUsage != nil {
            await self.flushPending(content: pendingContent, usage: pendingUsage, into: assistantID)
        }

        return StreamRoundResult(
            toolUseOrder: toolUseOrder,
            toolUseNames: toolUseNames,
            toolUseInputs: toolUseInputs,
            cancelled: Task.isCancelled
        )
    }

    nonisolated static func buildSystemPrompt(_ promptContext: PromptContext?, mode: AIChatMode) -> String? {
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
        guard let schemaPrompt, !schemaPrompt.isEmpty else { return modeNote }
        return "\(schemaPrompt)\n\n\(modeNote)"
    }

    private func failTooManyRoundtrips(assistantID: UUID) async {
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.errorMessage = String(
                localized: "AI made too many tool calls in one response. Try simplifying the request."
            )
            if let idx = self.messages.firstIndex(where: { $0.id == assistantID }),
               self.messages[idx].plainText.isEmpty {
                self.messages.remove(at: idx)
            }
            self.streamingState = .failed(nil)
        }
    }

    func completeToolRoundtrip(
        assistantIDForRound: UUID,
        toolUseBlocks: [ToolUseBlock],
        toolResultBlocks: [ToolResultBlock],
        resolved: AIProviderFactory.ResolvedProvider
    ) async -> ToolRoundtripContinuation {
        await MainActor.run { [weak self] () -> ToolRoundtripContinuation in
            let assistantText: String = {
                guard let self,
                      let idx = self.messages.firstIndex(where: { $0.id == assistantIDForRound })
                else { return "" }
                return self.messages[idx].plainText
            }()
            var assistantBlocks: [ChatContentBlock] = []
            if !assistantText.isEmpty { assistantBlocks.append(.text(assistantText)) }
            assistantBlocks.append(contentsOf: toolUseBlocks.map { .toolUse($0) })
            let assistantTurn = ChatTurn(
                id: assistantIDForRound,
                role: .assistant,
                blocks: assistantBlocks,
                modelId: resolved.model,
                providerId: resolved.config.id.uuidString
            )
            let userTurn = ChatTurn(
                role: .user,
                blocks: toolResultBlocks.map { .toolResult($0) }
            )
            let nextAssistant = ChatTurn(
                role: .assistant,
                blocks: [],
                modelId: resolved.model,
                providerId: resolved.config.id.uuidString
            )
            self?.messages.append(userTurn)
            self?.messages.append(nextAssistant)
            self?.streamingState = .streaming(assistantID: nextAssistant.id)
            return ToolRoundtripContinuation(
                nextAssistantID: nextAssistant.id,
                assistantTurn: assistantTurn,
                userTurn: userTurn
            )
        }
    }

    func flushPending(content: String, usage: AITokenUsage?, into assistantID: UUID) async {
        guard !content.isEmpty || usage != nil else { return }
        await MainActor.run { [weak self] in
            guard let self,
                  let idx = self.messages.firstIndex(where: { $0.id == assistantID })
            else { return }
            if !content.isEmpty {
                self.messages[idx].appendText(content)
            }
            if let usage {
                self.messages[idx].usage = usage
            }
        }
    }

    func preflightCheck(systemPrompt: String?, turns: [ChatTurn], assistantID: UUID) async -> Bool {
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
        inputs: [String: String]
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
            return ToolUseBlock(id: id, name: name, input: inputValue)
        }
    }

    nonisolated static func executeToolUses(
        _ blocks: [ToolUseBlock],
        mode: AIChatMode,
        context: ChatToolContext,
        registry: ChatToolRegistry? = nil
    ) async -> [ToolResultBlock] {
        await withTaskGroup(of: (Int, ToolResultBlock).self) { group in
            for (index, block) in blocks.enumerated() {
                group.addTask {
                    (index, await runToolUse(block, mode: mode, context: context, registry: registry))
                }
            }
            var indexed: [(Int, ToolResultBlock)] = []
            for await pair in group { indexed.append(pair) }
            return indexed.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
    }

    nonisolated private static func runToolUse(
        _ block: ToolUseBlock,
        mode: AIChatMode,
        context: ChatToolContext,
        registry: ChatToolRegistry?
    ) async -> ToolResultBlock {
        if Task.isCancelled {
            return ToolResultBlock(toolUseId: block.id, content: "Cancelled", isError: true)
        }
        guard ChatToolRegistry.isToolAllowed(name: block.name, in: mode) else {
            AIChatViewModel.logger.warning(
                "Tool '\(block.name, privacy: .public)' blocked in \(mode.rawValue, privacy: .public) mode"
            )
            return ToolResultBlock(
                toolUseId: block.id,
                content: "Tool '\(block.name)' is not available in \(mode.displayName) mode",
                isError: true
            )
        }
        let tool = await MainActor.run {
            (registry ?? ChatToolRegistry.shared).tool(named: block.name, in: mode)
        }
        guard let tool else {
            AIChatViewModel.logger.warning("Tool '\(block.name, privacy: .public)' not registered; returning error")
            return ToolResultBlock(
                toolUseId: block.id,
                content: "Tool '\(block.name)' is not available",
                isError: true
            )
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
