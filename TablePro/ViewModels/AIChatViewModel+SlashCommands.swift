//
//  AIChatViewModel+SlashCommands.swift
//  TablePro
//

import Foundation
import os

extension AIChatViewModel {
    static let helpMarkdown: String = {
        let lines = SlashCommand.allCommands
            .map { "- `/\($0.name)` · \($0.description)" }
            .joined(separator: "\n")
        return String(localized: "**Available commands:**") + "\n\n" + lines
    }()

    func runSlashCommand(_ command: SlashCommand, body: String = "") {
        inputText = ""
        clearError()

        let invocationText = body.isEmpty ? "/\(command.name)" : "/\(command.name) \(body)"
        let databaseType = connection?.type ?? .mysql

        switch command {
        case .help:
            let helpMarkdown = Self.helpMarkdown
            if let last = messages.last, last.role == .assistant, last.plainText == helpMarkdown {
                return
            }
            messages.append(ChatTurn(role: .user, blocks: [.text(invocationText)]))
            messages.append(ChatTurn(role: .assistant, blocks: [.text(helpMarkdown)]))
        case .explain:
            guard let query = resolveQuery(body: body, command: command) else { return }
            messages.append(ChatTurn(role: .user, blocks: [.text(invocationText)]))
            sendWithWalkthroughContext(
                prompt: AIPromptTemplates.explainQuery(query, databaseType: databaseType),
                beforeSQL: query
            )
        case .optimize:
            guard let query = resolveQuery(body: body, command: command) else { return }
            messages.append(ChatTurn(role: .user, blocks: [.text(invocationText)]))
            sendWithWalkthroughContext(
                prompt: AIPromptTemplates.optimizeQuery(query, databaseType: databaseType),
                beforeSQL: query
            )
        case .fix:
            guard let query = resolveQuery(body: body, command: command) else { return }
            messages.append(ChatTurn(role: .user, blocks: [.text(invocationText)]))
            let lastError = queryResults ?? ""
            sendWithWalkthroughContext(
                prompt: AIPromptTemplates.fixError(query: query, error: lastError, databaseType: databaseType),
                beforeSQL: query
            )
        }
    }

    func runCustomSlashCommand(_ command: CustomSlashCommand, body: String = "") async {
        guard command.isValid else {
            Self.logger.warning("runCustomSlashCommand called with invalid command: name=\(command.name, privacy: .public)")
            return
        }
        inputText = ""
        clearError()
        let invocationText = body.isEmpty ? "/\(command.name)" : "/\(command.name) \(body)"
        let needsSchema = command.promptTemplate.contains(CustomSlashCommandVariable.schema.placeholder)
        if needsSchema {
            await ensureSchemaLoaded()
        }
        let renderingContext = CustomSlashCommandRenderer.Context(
            query: currentQuery,
            schema: needsSchema ? renderedSchemaSection() : nil,
            database: connection.flatMap { services.databaseManager.activeDatabaseName(for: $0) },
            body: body
        )
        let prompt = CustomSlashCommandRenderer.render(command, context: renderingContext)
        messages.append(ChatTurn(role: .user, blocks: [.text(invocationText)]))
        sendWithContext(prompt: prompt)
    }

    func handleExplainSelection(_ selectedText: String) {
        guard !selectedText.isEmpty else { return }
        startNewConversation()
        let databaseType = connection?.type ?? .mysql
        let prompt = AIPromptTemplates.explainQuery(selectedText, databaseType: databaseType)
        sendWithWalkthroughContext(prompt: prompt, beforeSQL: selectedText)
    }

    func handleOptimizeSelection(_ selectedText: String) {
        guard !selectedText.isEmpty else { return }
        startNewConversation()
        let databaseType = connection?.type ?? .mysql
        let prompt = AIPromptTemplates.optimizeQuery(selectedText, databaseType: databaseType)
        sendWithWalkthroughContext(prompt: prompt, beforeSQL: selectedText)
    }

    private func resolveQuery(body: String, command: SlashCommand) -> String? {
        if !body.isEmpty {
            return body
        }
        if let editorQuery = currentQuery, !editorQuery.isEmpty {
            return editorQuery
        }
        errorMessage = String(
            format: String(localized: "/%@ needs a query: type one in the editor or after the command."),
            command.name
        )
        return nil
    }
}
