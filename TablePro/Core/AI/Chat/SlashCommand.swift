//
//  SlashCommand.swift
//  TablePro
//

import Foundation

enum SlashCommand: String, CaseIterable, Identifiable, Sendable {
    case explain
    case optimize
    case fix
    case help

    var id: String { rawValue }

    var name: String { rawValue }

    var description: String {
        switch self {
        case .explain: return String(localized: "Explain the current query")
        case .optimize: return String(localized: "Suggest optimizations for the current query")
        case .fix: return String(localized: "Fix the last error on the current query")
        case .help: return String(localized: "List available commands")
        }
    }

    var requiresQuery: Bool {
        switch self {
        case .explain, .optimize, .fix: return true
        case .help: return false
        }
    }

    static let allCommands: [SlashCommand] = allCases

    /// Parses a typed input. Returns the command and any body text after it,
    /// or nil if the text doesn't start with a known slash command.
    /// Examples:
    ///   "/explain"               -> (.explain, "")
    ///   "/explain SELECT 1"      -> (.explain, "SELECT 1")
    ///   "/Notacommand"           -> nil
    ///   "hello"                  -> nil
    static func parse(_ text: String) -> (command: SlashCommand, body: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let afterSlash = trimmed.dropFirst()
        let nameSubstring = afterSlash.prefix(while: { !$0.isWhitespace })
        let name = String(nameSubstring).lowercased()
        guard let command = SlashCommand(rawValue: name) else { return nil }
        let body = afterSlash
            .dropFirst(nameSubstring.count)
            .trimmingCharacters(in: .whitespaces)
        return (command, body)
    }

    static func match(prefix: String) -> [SlashCommand] {
        guard prefix.hasPrefix("/") else { return [] }
        let typed = prefix.dropFirst().lowercased()
        if typed.isEmpty { return allCases }
        return allCases.filter { $0.name.hasPrefix(typed) }
    }
}
