//
//  AIChatViewModel+QueryActions.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

extension AIChatViewModel {
    static let queryActionStatementLimit = 60_000

    static func rejection(for request: AIQueryRequest) -> String? {
        let length = (request.trimmedStatement as NSString).length
        guard length > queryActionStatementLimit else { return nil }
        return String(
            format: String(localized: "This statement is too long to send (%d characters). Select a smaller part of it."),
            length
        )
    }

    func runQueryAction(_ request: AIQueryRequest, invocationText: String? = nil) {
        guard !request.trimmedStatement.isEmpty else { return }
        if let rejection = Self.rejection(for: request) {
            errorMessage = rejection
            return
        }

        if let invocationText {
            messages.append(ChatTurn(role: .user, blocks: [.text(invocationText)]))
        } else {
            startNewConversation()
            currentQuery = request.editorText ?? request.statement
            queryResults = nil
        }

        let attachment = queryContextAttachment(for: request)
        var blocks: [ChatContentBlock] = [.text(queryActionPrompt(for: request, withStructure: attachment != nil))]
        if let attachment {
            blocks.append(.attachment(.queryContext(attachment)))
        }
        messages.append(ChatTurn(role: .user, blocks: blocks))
        trimMessagesIfNeeded()
        clearError()
        pendingWalkthroughBeforeSQL = request.statement
        pendingWalkthroughSource = request.source
        startStreaming()
    }

    func queryActionPrompt(for request: AIQueryRequest, withStructure: Bool) -> String {
        let info = AIPromptTemplates.queryInfo(for: request.databaseType)
        return AIPromptTemplates.queryActionPrompt(
            request.action,
            statement: request.statement,
            typeName: info.typeName,
            language: info.language,
            withStructure: withStructure,
            errorMessage: request.errorMessage,
            explainPlan: withStructure ? nil : request.explainPlan
        )
    }

    func queryContextAttachment(for request: AIQueryRequest) -> QueryContextAttachment? {
        guard services.appSettings.ai.includeSchema,
              let scope = request.scope ?? connection.flatMap({ services.databaseManager.browseScope(for: $0.id) })
        else { return nil }
        return QueryContextAttachment(
            connectionId: scope.connectionId,
            database: scope.database,
            schema: scope.schema,
            statement: request.statement,
            explainPlan: request.explainPlan
        )
    }

    func materializeQueryContexts(in turn: ChatTurn) async {
        var changed = false
        for block in turn.blocks {
            guard case .attachment(.queryContext(let attachment)) = block.kind, !attachment.isResolved else { continue }
            let snapshot = await buildQueryContext(for: attachment)
            guard !Task.isCancelled else { return }
            block.setKind(.attachment(.queryContext(attachment.resolved(with: snapshot))))
            changed = true
        }
        if changed {
            turn.objectWillChange.send()
        }
    }

    private func buildQueryContext(for attachment: QueryContextAttachment) async -> QueryContextSnapshot {
        guard let connection, connection.id == attachment.connectionId else {
            return QueryContextSnapshot(engineName: "", databaseName: attachment.database, schemaName: attachment.schema)
        }
        let input = QueryContextInput.make(
            statement: attachment.statement,
            scope: attachment.scope,
            databaseType: connection.type,
            serverVersion: services.databaseManager.driver(for: connection.id)?.serverVersion,
            explainPlan: attachment.explainPlan
        )
        return await QueryContextBuilder(metadata: queryContextMetadata).build(input)
    }
}
