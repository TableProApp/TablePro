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
        guard !isStreaming else { return }
        inputText = ""
        clearError()

        let invocationText = body.isEmpty ? "/\(command.name)" : "/\(command.name) \(body)"
        guard let action = command.queryAction else {
            showHelp(invocationText: invocationText)
            return
        }
        guard let request = slashRequest(for: action, command: command, body: body) else { return }
        runQueryAction(request, invocationText: invocationText)
    }

    func runCustomSlashCommand(_ command: CustomSlashCommand, body: String = "") async {
        guard command.isValid else {
            Self.logger.warning("runCustomSlashCommand called with invalid command: name=\(command.name, privacy: .public)")
            return
        }
        guard !isStreaming else { return }
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
            database: connection.flatMap { services.databaseManager.browseDatabaseName(for: $0) },
            body: body
        )
        let prompt = CustomSlashCommandRenderer.render(command, context: renderingContext)
        messages.append(ChatTurn(role: .user, blocks: [.text(invocationText)]))
        sendWithContext(prompt: prompt)
    }

    private func showHelp(invocationText: String) {
        let helpMarkdown = Self.helpMarkdown
        if let last = messages.last, last.role == .assistant, last.plainText == helpMarkdown {
            return
        }
        messages.append(ChatTurn(role: .user, blocks: [.text(invocationText)]))
        messages.append(ChatTurn(role: .assistant, blocks: [.text(helpMarkdown)]))
    }

    private func slashRequest(for action: AIQueryAction, command: SlashCommand, body: String) -> AIQueryRequest? {
        let databaseType = connection?.type ?? .mysql
        let target = editorTarget
        let statement: String
        var failure: String?

        if action == .fixError {
            guard let error = target?.errorMessage, !error.isEmpty else {
                errorMessage = String(localized: "/fix needs a query that failed. Run the query first.")
                return nil
            }
            failure = error
            statement = body.isEmpty ? (target?.errorQuery ?? currentQuery ?? "") : body
        } else {
            statement = body.isEmpty ? (currentQuery ?? "") : body
        }

        guard !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = String(
                format: String(localized: "/%@ needs a query: type one in the editor or after the command."),
                command.name
            )
            return nil
        }

        return AIQueryRequest(
            action: action,
            statement: statement,
            editorText: currentQuery,
            scope: target?.scope,
            databaseType: databaseType,
            source: body.isEmpty ? target.map { QueryEditorAnchor(tabId: $0.tabId) } : nil,
            errorMessage: failure
        )
    }
}
