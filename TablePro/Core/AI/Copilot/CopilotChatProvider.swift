//
//  CopilotChatProvider.swift
//  TablePro
//

import Foundation
import os

final class CopilotChatProvider: ChatTransport {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CopilotChatProvider")

    private var conversationId: String?
    private var turnIds: [String] = []
    private let progressHandlers = OSAllocatedUnfairLock(
        initialState: [String: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation]()
    )
    private var isProgressHandlerRegistered = false

    func streamChat(
        turns: [ChatTurn],
        options: ChatTransportOptions
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
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

                    self.progressHandlers.withLock { $0[token] = continuation }

                    let userMessage = turns.last(where: { $0.role == .user })?.plainText ?? ""
                    let effectiveModel: String? = options.model.isEmpty ? nil : options.model

                    if self.conversationId == nil {
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
                            workspaceFolders: nil
                        )
                        let result = try await client.conversationCreate(params: params)
                        self.conversationId = result.conversationId
                        self.turnIds.append(result.turnId)
                        Self.logger.info("Created Copilot conversation: \(result.conversationId)")
                    } else if let conversationId = self.conversationId {
                        let params = CopilotConversationTurnParams(
                            workDoneToken: token,
                            conversationId: conversationId,
                            message: userMessage,
                            source: "panel",
                            model: effectiveModel,
                            workspaceFolders: nil
                        )
                        let result = try await client.conversationTurn(params: params)
                        self.turnIds.append(result.turnId)
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

    func fetchAvailableModels() async throws -> [String] {
        guard let client = await CopilotService.shared.client else {
            throw CopilotError.serverNotRunning
        }
        let models = try await client.fetchCopilotModels()
        let chatModels = models.filter { $0.scopes?.contains("chat-panel") ?? false }
        let sorted = chatModels.sorted { ($0.isChatDefault ?? false) && !($1.isChatDefault ?? false) }
        return sorted.map(\.id)
    }

    func testConnection() async throws -> Bool {
        await CopilotService.shared.isAuthenticated
    }

    func resetConversation() {
        isProgressHandlerRegistered = false
        let id = conversationId
        conversationId = nil
        turnIds.removeAll()
        guard let id else { return }
        Task { @MainActor in
            guard let client = CopilotService.shared.client else { return }
            try? await client.conversationDestroy(conversationId: id)
            Self.logger.info("Destroyed Copilot conversation: \(id)")
        }
    }

    func deleteLastTurn() {
        guard let conversationId, let turnId = turnIds.popLast() else { return }
        Task { @MainActor in
            guard let client = CopilotService.shared.client else { return }
            try? await client.conversationTurnDelete(conversationId: conversationId, turnId: turnId)
        }
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
