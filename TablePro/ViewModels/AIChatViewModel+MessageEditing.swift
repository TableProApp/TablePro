//
//  AIChatViewModel+MessageEditing.swift
//  TablePro
//

import Foundation

extension AIChatViewModel {
    func editMessage(_ message: ChatTurn) {
        guard message.role == .user, !isStreaming else { return }
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else { return }

        inputText = message.plainText
        attachedContext = message.blocks.compactMap { block in
            if case .attachment(let item) = block { return item }
            return nil
        }
        messages.removeSubrange(idx...)
        persistCurrentConversation()
    }

    func resolveTurnForWire(_ turn: ChatTurn) async -> ChatTurn {
        let attachments = turn.blocks.compactMap { block -> ContextItem? in
            if case .attachment(let item) = block { return item }
            return nil
        }
        guard !attachments.isEmpty else { return turn }

        for item in attachments {
            await primeAttachmentData(for: item)
        }

        let typed = turn.blocks.compactMap { block -> String? in
            if case .text(let value) = block { return value }
            return nil
        }.joined()

        let resolved = attachments
            .compactMap { resolveAttachment($0) }
            .joined(separator: "\n\n")
        if resolved.isEmpty { return turn }

        let combined = typed.isEmpty ? resolved : typed + "\n\n---\n\n" + resolved
        return ChatTurn(
            id: turn.id,
            role: turn.role,
            blocks: [.text(combined)],
            timestamp: turn.timestamp,
            usage: turn.usage,
            modelId: turn.modelId,
            providerId: turn.providerId
        )
    }

    func resolveAttachment(_ item: ContextItem) -> String? {
        switch item {
        case .schema:
            return resolveSchemaAttachment()
        case .table(_, let name):
            return resolveTableAttachment(name: name)
        case .currentQuery(let text):
            let snapshot = text.isEmpty ? (currentQuery ?? "") : text
            guard !snapshot.isEmpty else { return nil }
            return "## Current Query\n```\n\(snapshot)\n```"
        case .queryResult(let summary):
            let snapshot = summary.isEmpty ? (queryResults ?? "") : summary
            guard !snapshot.isEmpty else { return nil }
            return "## Query Results\n\(snapshot)"
        case .savedQuery(let id, let name):
            return resolveSavedQueryAttachment(id: id, fallbackName: name)
        case .file:
            return nil
        }
    }

    private func resolveSavedQueryAttachment(id: UUID, fallbackName: String) -> String? {
        guard let favorite = cachedSavedQueries[id] else { return nil }
        let displayName = favorite.name.isEmpty ? fallbackName : favorite.name
        let header = displayName.isEmpty
            ? String(localized: "Saved Query")
            : "\(String(localized: "Saved Query")): \(displayName)"
        return "## \(header)\n```sql\n\(favorite.query)\n```"
    }

    private func resolveSchemaAttachment() -> String? {
        guard let section = renderedSchemaSection() else { return nil }
        return "## Schema\n\(section)"
    }

    private func resolveTableAttachment(name: String) -> String? {
        let columns = columnsByTable[name] ?? []
        guard !columns.isEmpty else { return nil }
        let foreignKeys = foreignKeysByTable[name] ?? []
        var lines: [String] = ["## Table \(name)"]
        for column in columns {
            lines.append("- \(column.name): \(column.dataType)")
        }
        if !foreignKeys.isEmpty {
            lines.append("Foreign keys:")
            for foreign in foreignKeys {
                lines.append("- \(foreign.column) -> \(foreign.referencedTable).\(foreign.referencedColumn)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
