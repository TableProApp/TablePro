//
//  SlashCommand.swift
//  TablePro
//

import Foundation

enum SlashCommand: String, CaseIterable, Identifiable, Sendable {
    case review
    case explain
    case optimize
    case fix
    case help

    var id: String { rawValue }

    var name: String { rawValue }

    var description: String {
        switch self {
        case .review: return String(localized: "Review the current query against its tables")
        case .explain: return String(localized: "Explain the current query")
        case .optimize: return String(localized: "Suggest optimizations for the current query")
        case .fix: return String(localized: "Fix the last error on the current query")
        case .help: return String(localized: "List available commands")
        }
    }

    var queryAction: AIQueryAction? {
        switch self {
        case .review: return .review
        case .explain: return .explain
        case .optimize: return .optimize
        case .fix: return .fixError
        case .help: return nil
        }
    }

    var requiresQuery: Bool {
        queryAction != nil
    }

    static let allCommands: [SlashCommand] = allCases

    static func isBuiltIn(name: String) -> Bool {
        SlashCommand(rawValue: name.trimmingCharacters(in: .whitespaces).lowercased()) != nil
    }

    static func parse(_ text: String) -> (command: SlashCommand, body: String)? {
        guard let invocation = invocation(in: text),
              let command = SlashCommand(rawValue: invocation.name.lowercased())
        else { return nil }
        return (command, invocation.body)
    }

    static func invocation(in text: String) -> (name: String, body: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let afterSlash = trimmed.dropFirst()
        let name = afterSlash.prefix(while: { !$0.isWhitespace })
        guard !name.isEmpty else { return nil }
        let body = afterSlash
            .dropFirst(name.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(name), body)
    }

    static func match(prefix: String) -> [SlashCommand] {
        guard prefix.hasPrefix("/") else { return [] }
        let typed = prefix.dropFirst().lowercased()
        if typed.isEmpty { return allCases }
        return allCases.filter { $0.name.hasPrefix(typed) }
    }
}
