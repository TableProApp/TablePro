//
//  CopilotChatProvider.swift
//  TablePro
//

import Foundation
import os

final class CopilotChatProvider: ChatTransport, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CopilotChatProvider")

    /// Copilot keeps the conversation on its own side, and one provider instance is shared by every
    /// chat session on a configuration, so the conversation has to be keyed by session rather than
    /// held as a single field. It used to be a single field: two sessions on one Copilot
    /// configuration appended their turns to one server-side conversation, so each of them was
    /// answered with the other's context, across connections included, while their local
    /// transcripts stayed correctly separate. `ProviderStreamLease` cannot fix that, because it
    /// serializes turns and never swaps what the provider is pointing at.
    ///
    /// Keyed on the optional itself, so a caller with no session, a connection test or an inline
    /// suggestion, shares one conversation under `nil` rather than needing a sentinel id.
    private struct Conversation {
        var id: String
        var turnIds: [String] = []
        var chatMode: String?
    }

    private var conversations: [UUID?: Conversation] = [:]
    private let progressHandlers = OSAllocatedUnfairLock(
        initialState: [String: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation]()
    )
    private var isProgressHandlerRegistered = false
    private var isInvokeClientToolHandlerRegistered = false
    private var registeredToolNames: Set<String> = []
    private let activeStream = OSAllocatedUnfairLock<(UUID, AsyncThrowingStream<ChatStreamEvent, Error>.Continuation)?>(
        initialState: nil
    )

    func streamChat(
        turns: [ChatTurnWire],
        options: ChatTransportOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            /// Identifies this one stream, not the chat session it belongs to. The session is
            /// `options.sessionId` and outlives every stream on it.
            let streamId = UUID()
            continuation.onTermination = { [weak self] _ in
                self?.activeStream.withLock { current in
                    if current?.0 == streamId { current = nil }
                }
            }
            let task = Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let token = "copilot-chat-\(UUID().uuidString)"
                do {
                    guard let client = CopilotService.shared.client else {
                        throw CopilotError.serverNotRunning
                    }
                    guard CopilotService.shared.isAuthenticated else {
                        throw CopilotError.authenticationFailed(
                            String(localized: "Not signed in to GitHub Copilot")
                        )
                    }

                    await self.ensureProgressHandler()
                    await self.ensureInvokeClientToolHandler()
                    await self.ensureToolsRegistered(tools: options.tools)

                    let session = options.sessionId
                    let desiredChatMode: String? = (!options.tools.isEmpty && !self.registeredToolNames.isEmpty)
                        ? "Agent" : nil
                    /// A mode change is a property of the conversation, so only this session's is
                    /// dropped. Clearing a shared field used to reset whichever conversation the
                    /// provider happened to be holding.
                    if let existing = self.conversations[session], existing.chatMode != desiredChatMode {
                        Self.logger.info(
                            "Copilot chat mode changed; resetting this session's conversation to apply it"
                        )
                        self.conversations[session] = nil
                    }

                    self.progressHandlers.withLock { $0[token] = continuation }
                    self.activeStream.withLock { $0 = (streamId, continuation) }

                    let userMessage = turns.last(where: { $0.role == .user })?.plainText ?? ""
                    let effectiveModel: String? = options.model.isEmpty ? nil : options.model
                    let toolsAvailable = !options.tools.isEmpty && !self.registeredToolNames.isEmpty

                    if self.conversations[session] == nil {
                        let systemPrefix = options.systemPrompt.map { $0 + "\n\n" } ?? ""
                        let conversationTurns = [CopilotConversationTurn(
                            request: systemPrefix + userMessage,
                            response: "",
                            turnId: ""
                        )]
                        let params = CopilotConversationCreateParams(
                            workDoneToken: token,
                            turns: conversationTurns,
                            capabilities: CopilotConversationCapabilities(
                                skills: ["current-editor"],
                                allSkills: true
                            ),
                            source: "panel",
                            model: effectiveModel,
                            workspaceFolders: nil,
                            chatMode: toolsAvailable ? "Agent" : nil,
                            customChatModeId: toolsAvailable ? "Agent" : nil,
                            needToolCallConfirmation: toolsAvailable ? false : nil
                        )
                        let result = try await client.conversationCreate(params: params)
                        self.conversations[session] = Conversation(
                            id: result.conversationId,
                            turnIds: [result.turnId],
                            chatMode: desiredChatMode
                        )
                        Self.logger.info("Created Copilot conversation: \(result.conversationId)")
                    } else if let conversation = self.conversations[session] {
                        let params = CopilotConversationTurnParams(
                            workDoneToken: token,
                            conversationId: conversation.id,
                            message: userMessage,
                            source: "panel",
                            model: effectiveModel,
                            workspaceFolders: nil,
                            chatMode: toolsAvailable ? "Agent" : nil,
                            customChatModeId: toolsAvailable ? "Agent" : nil,
                            needToolCallConfirmation: toolsAvailable ? false : nil
                        )
                        let result = try await client.conversationTurn(params: params)
                        self.conversations[session]?.turnIds.append(result.turnId)
                    }
                } catch {
                    self.progressHandlers.withLock { $0.removeValue(forKey: token) }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func fetchAvailableModels() async throws -> [AIModelInfo] {
        guard let client = await CopilotService.shared.client else {
            throw CopilotError.serverNotRunning
        }
        let models = try await client.fetchCopilotModels()
        let chatModels = models.filter { $0.scopes?.contains("chat-panel") ?? false }
        let sorted = chatModels.sorted { ($0.isChatDefault ?? false) && !($1.isChatDefault ?? false) }
        return sorted.map { AIModelInfo(id: $0.id, displayName: $0.modelName) }
    }

    func testConnection() async throws -> Bool {
        await CopilotService.shared.isAuthenticated
    }

    /// Ends one session's conversation and leaves every other session's alone.
    ///
    /// The progress handler is not disturbed. It is registered once per language server client, not
    /// per conversation, and clearing its flag here used to force a re-registration that any other
    /// session's in-flight stream was relying on.
    func resetConversation(sessionId: UUID?) {
        guard let conversation = conversations.removeValue(forKey: sessionId) else { return }
        Task { @MainActor in
            guard let client = CopilotService.shared.client else { return }
            try? await client.conversationDestroy(conversationId: conversation.id)
            Self.logger.info("Destroyed Copilot conversation: \(conversation.id)")
        }
    }

    func deleteLastTurn(sessionId: UUID?) {
        guard var conversation = conversations[sessionId], let turnId = conversation.turnIds.popLast() else {
            return
        }
        let conversationId = conversation.id
        conversations[sessionId] = conversation
        Task { @MainActor in
            guard let client = CopilotService.shared.client else { return }
            try? await client.conversationTurnDelete(conversationId: conversationId, turnId: turnId)
        }
    }

    @MainActor
    private func ensureToolsRegistered(tools: [ChatToolSpec]) async {
        let names = Set(tools.map(\.name))
        guard names != registeredToolNames else { return }
        guard let client = CopilotService.shared.client else { return }
        do {
            let info = tools.map { $0.asCopilotToolInformation() }
            try await client.registerTools(CopilotRegisterToolsParams(tools: info))
            registeredToolNames = names
            Self.logger.info("Registered \(info.count) Copilot tools")
        } catch {
            Self.logger.warning(
                "Copilot tools registration failed (likely older language server): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    @MainActor
    private func ensureInvokeClientToolHandler() async {
        guard !isInvokeClientToolHandlerRegistered else { return }
        isInvokeClientToolHandlerRegistered = true
        guard let client = CopilotService.shared.client else { return }
        let activeStream = activeStream
        await client.onDeferredRequest(method: "conversation/invokeClientTool") { data, requestId in
            Task { @MainActor in
                await Self.handleInvokeClientTool(
                    data: data,
                    requestId: requestId,
                    activeStream: activeStream
                )
            }
        }
    }

    private struct InvokeClientToolEnvelope: Decodable {
        let params: CopilotInvokeClientToolParams
    }

    @MainActor
    private static func handleInvokeClientTool(
        data: Data,
        requestId: Int,
        activeStream: OSAllocatedUnfairLock<(UUID, AsyncThrowingStream<ChatStreamEvent, Error>.Continuation)?>
    ) async {
        let params: CopilotInvokeClientToolParams
        do {
            let envelope = try JSONDecoder().decode(InvokeClientToolEnvelope.self, from: data)
            params = envelope.params
        } catch {
            Self.logger.error("Failed to decode invokeClientTool params: \(error.localizedDescription, privacy: .public)")
            if let raw = String(data: data, encoding: .utf8) {
                Self.logger.error("Raw invokeClientTool payload: \(raw, privacy: .public)")
            }
            await Self.sendErrorReply(requestId: requestId, message: "Failed to decode tool invocation")
            return
        }
        Self.logger.info(
            "Copilot invoked tool '\(params.name, privacy: .public)' (turn=\(params.turnId, privacy: .public))"
        )

        let toolBlock = ToolUseBlock(
            id: "\(params.conversationId)-\(params.turnId)-\(params.name)-\(UUID().uuidString)",
            name: params.name,
            input: params.input ?? .object([:]),
            approvalState: .pending
        )

        let replyToken = ToolReplyToken { result in
            await Self.sendToolReply(requestId: requestId, result: result)
        }

        guard let continuation = activeStream.withLock({ $0?.1 }) else {
            Self.logger.warning("No active stream continuation for invokeClientTool; cancelling")
            await Self.sendErrorReply(requestId: requestId, message: "No active chat session")
            return
        }
        continuation.yield(.toolInvocationRequest(block: toolBlock, replyToken: replyToken))
    }

    @MainActor
    private static func sendToolReply(requestId: Int, result: ChatToolResult) async {
        guard let client = CopilotService.shared.client else { return }
        let status: CopilotToolInvocationStatus = result.isError ? .error : .success
        let lspResult = CopilotLanguageModelToolResult(
            status: status,
            content: [CopilotLanguageModelToolResultContent(value: .string(result.content))]
        )
        let preview = result.content.prefix(200)
        Self.logger.info(
            "Replying to invokeClientTool requestId=\(requestId) status=\(status.rawValue, privacy: .public) preview=\(preview, privacy: .public)"
        )
        do {
            try await client.sendInvokeClientToolResponse(id: requestId, result: lspResult)
        } catch {
            Self.logger.error("Failed to reply to invokeClientTool: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    private static func sendErrorReply(requestId: Int, message: String) async {
        let result = ChatToolResult(content: message, isError: true)
        await sendToolReply(requestId: requestId, result: result)
    }

    @MainActor
    private func ensureProgressHandler() async {
        guard !isProgressHandlerRegistered else { return }
        isProgressHandlerRegistered = true

        guard let client = CopilotService.shared.client else { return }
        let handlers = progressHandlers

        await client.onNotification(method: "$/progress") { data in
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let params = json["params"] as? [String: Any],
                  let token = params["token"] as? String,
                  let value = params["value"] as? [String: Any],
                  let kind = value["kind"] as? String
            else { return }

            let continuation = handlers.withLock { $0[token] }
            guard let continuation else { return }

            switch kind {
            case "report":
                var reply = value["reply"] as? String
                if reply == nil,
                   let rounds = value["editAgentRounds"] as? [[String: Any]],
                   let last = rounds.last {
                    reply = last["reply"] as? String
                }
                if let reply, !reply.isEmpty {
                    continuation.yield(.textDelta(reply))
                }

                if let usage = value["tokenUsage"] as? [String: Any],
                   let promptTokens = usage["promptTokens"] as? Int,
                   let completionTokens = usage["completionTokens"] as? Int {
                    continuation.yield(.usage(AITokenUsage(
                        inputTokens: promptTokens,
                        outputTokens: completionTokens
                    )))
                }
            case "end":
                handlers.withLock { $0.removeValue(forKey: token) }
                continuation.finish()
            default:
                break
            }
        }
    }
}
