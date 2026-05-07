//
//  SlashCommand.swift
//  TablePro
//

import Foundation

struct SlashCommand: Identifiable, Sendable {
    let name: String
    let descriptionKey: String.LocalizationValue
    let requiresQuery: Bool

    var id: String { name }

    var description: String {
        String(localized: descriptionKey)
    }

    static let allCommands: [SlashCommand] = [
        SlashCommand(
            name: "explain",
            descriptionKey: "Explain the current query",
            requiresQuery: true
        ),
        SlashCommand(
            name: "optimize",
            descriptionKey: "Suggest optimizations for the current query",
            requiresQuery: true
        ),
        SlashCommand(
            name: "fix",
            descriptionKey: "Fix the last error on the current query",
            requiresQuery: true
        ),
        SlashCommand(
            name: "help",
            descriptionKey: "List available commands",
            requiresQuery: false
        )
    ]

    static func match(prefix: String) -> [SlashCommand] {
        guard prefix.hasPrefix("/") else { return [] }
        let typed = prefix.dropFirst().lowercased()
        if typed.isEmpty { return allCommands }
        return allCommands.filter { $0.name.hasPrefix(typed) }
    }

    static func parse(_ text: String) -> SlashCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let head = trimmed
            .dropFirst()
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)
            .map { $0.lowercased() } ?? ""
        return allCommands.first { $0.name == head }
    }
}
