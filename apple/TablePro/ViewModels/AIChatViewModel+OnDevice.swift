//
//  AIChatViewModel+OnDevice.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

struct OnDeviceRefusal: Equatable {
    let turnID: UUID
    let walkthroughBeforeSQL: String?
    let walkthroughSource: QueryEditorAnchor?
}

extension AIChatViewModel {
    static let onDeviceReplyReserve = 1_024

    var answersLastTurnOnDevice: Bool {
        guard let onDeviceTurnID else { return false }
        return messages.last?.id == onDeviceTurnID
    }

    var fallbackProviderName: String? {
        let settings = services.appSettings.ai
        let config = selectedProviderId.flatMap { id in settings.providers.first { $0.id == id } }
            ?? settings.activeProvider
        return config?.displayName
    }

    func beginOnDeviceTurn() {
        guard let userTurn = messages.last, userTurn.role == .user else { return }
        let model = onDeviceModel
        if let unavailable = model.availability.unavailableExplanation {
            clearPendingWalkthrough()
            errorMessage = unavailable
            return
        }
        AIProviderFactory.resetCopilotConversation(sessionId: sessionId)
        let assistant = ChatTurn(
            role: .assistant,
            blocks: [],
            modelId: AppleIntelligenceAvailability.displayName,
            providerId: AppleIntelligenceAvailability.providerID
        )
        messages.append(assistant)
        trimMessagesIfNeeded()
        let assistantID = assistant.id
        streamingState = .streaming(assistantID: assistantID)
        let instructions = AIPromptTemplates.onDeviceQueryActionInstructions(
            engineName: connection.map { PluginMetadataRegistry.shared.snapshot(for: $0.type)?.displayName ?? $0.type.rawValue },
            connectionRules: connection?.aiRules
        )
        streamingTask = Task { [weak self] in
            await self?.answerOnDevice(userTurn: userTurn, assistantID: assistantID, model: model, instructions: instructions)
        }
    }

    func sendRefusedTurnToProvider() {
        guard let refusal = onDeviceRefusal, messages.last?.id == refusal.turnID else { return }
        onDeviceTurnID = nil
        clearError()
        pendingWalkthroughBeforeSQL = refusal.walkthroughBeforeSQL
        pendingWalkthroughSource = refusal.walkthroughSource
        startStreaming()
    }

    private func answerOnDevice(
        userTurn: ChatTurn,
        assistantID: UUID,
        model: any OnDeviceLanguageModel,
        instructions: String
    ) async {
        let pending = unresolvedQueryContext(in: userTurn)
        var snapshots: [QueryContextSnapshot] = []
        var candidates: [OnDeviceRequest] = []
        if let pending {
            let full = await buildQueryContext(for: pending.attachment)
            let grammar = connection.map {
                SQLLexicalResolver.executionGrammar(for: $0.type, connectionId: pending.attachment.connectionId)
            } ?? .ansi
            let trimmed = full.keepingColumns(usedBy: pending.attachment.statement, grammar: grammar)
            snapshots = trimmed == full ? [full] : [full, trimmed]
            candidates = snapshots.map { snapshot in
                OnDeviceRequest(
                    instructions: instructions,
                    prompt: Self.onDevicePrompt(typed: userTurn.plainText, context: QueryContextRenderer.render(snapshot))
                )
            }
        } else {
            let wire = await resolveTurnForWire(userTurn)
            candidates = [OnDeviceRequest(instructions: instructions, prompt: wire.plainText)]
        }
        guard !Task.isCancelled else { return }

        let fit = await model.fit(candidates, reservingForReply: Self.onDeviceReplyReserve)
        guard !Task.isCancelled else { return }
        if connection != nil, resolveConnectionPolicy(settings: services.appSettings.ai) == .never {
            abandonOnDeviceTurn(assistantID: assistantID, message: String(localized: "AI is disabled for this connection."))
            return
        }
        guard case .fits(let index, let allowance) = fit else {
            refuseOnDevice(userTurnID: userTurn.id, assistantID: assistantID, trimmedStructure: pending != nil)
            return
        }
        if let pending, snapshots.indices.contains(index) {
            pending.block.setKind(.attachment(.queryContext(pending.attachment.resolved(with: snapshots[index]))))
            userTurn.objectWillChange.send()
        }

        do {
            for try await delta in model.streamResponse(to: candidates[index], maximumResponseTokens: allowance) {
                turn(withID: assistantID)?.appendStreamingToken(delta)
            }
            guard !Task.isCancelled else { return }
            finalizeStreamingMessage(id: assistantID)
            clearPendingWalkthrough()
            streamingState = .idle
            streamingTask = nil
            persistCurrentConversation()
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.error("On-device reply failed: \(error.publicLogShape, privacy: .public)")
            clearPendingWalkthrough()
            errorMessage = String(
                format: String(localized: "Apple Intelligence could not answer: %@"),
                error.localizedDescription
            )
            streamingState = .failed(nil)
            finalizeStreamingMessage(id: assistantID)
            if let index = messages.firstIndex(where: { $0.id == assistantID }), messages[index].blocks.isEmpty {
                messages.remove(at: index)
            }
            streamingTask = nil
        }
    }

    private func abandonOnDeviceTurn(assistantID: UUID, message: String) {
        messages.removeAll { $0.id == assistantID }
        clearPendingWalkthrough()
        streamingState = .idle
        streamingTask = nil
        errorMessage = message
    }

    private func refuseOnDevice(userTurnID: UUID, assistantID: UUID, trimmedStructure: Bool) {
        messages.removeAll { $0.id == assistantID }
        streamingState = .idle
        streamingTask = nil
        let refusal = OnDeviceRefusal(
            turnID: userTurnID,
            walkthroughBeforeSQL: pendingWalkthroughBeforeSQL,
            walkthroughSource: pendingWalkthroughSource
        )
        clearPendingWalkthrough()
        errorMessage = trimmedStructure ? Self.tooLargeWithTrimmedStructure : Self.tooLarge
        onDeviceRefusal = refusal
        persistCurrentConversation()
    }

    private static var tooLarge: String {
        String(localized: "This request is too large for Apple Intelligence. Select a smaller part of the statement.")
    }

    private static var tooLargeWithTrimmedStructure: String {
        String(
            localized: "This request is too large for Apple Intelligence, even with only the columns the statement uses. Select a smaller part of the statement."
        )
    }

    private func unresolvedQueryContext(in turn: ChatTurn) -> (block: ChatContentBlock, attachment: QueryContextAttachment)? {
        for block in turn.blocks {
            if case .attachment(.queryContext(let attachment)) = block.kind, !attachment.isResolved {
                return (block, attachment)
            }
        }
        return nil
    }

    private static func onDevicePrompt(typed: String, context: String) -> String {
        typed.isEmpty ? context : typed + "\n\n---\n\n" + context
    }
}
