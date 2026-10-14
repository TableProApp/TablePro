//
//  MongoShellCommandRecognizer.swift
//  TablePro
//

import Foundation

/// Recognises the two mongosh lines that are not JavaScript.
///
/// `use orders` and `show collections` are shell syntax, so a JavaScript parser rejects them and
/// the editor would underline a statement that runs perfectly well. The driver rewrites them into
/// the calls they stand for; nothing here needs to, because all the editor has to decide is whether
/// to look for a syntax error.
///
/// Deliberately not shared with the driver through TableProPluginKit. A new public symbol there is
/// missing from every already-shipped app, so a plugin built against it stops loading on the
/// version most people are running, and the MongoDB plugin ships from the registry ahead of the app.
enum MongoShellCommandRecognizer {
    private static let shownTopics: Set<String> = ["dbs", "databases", "collections", "tables"]

    static func isShellCommand(_ statement: String) -> Bool {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        if argument(after: "use", in: trimmed) != nil { return true }
        guard let topic = argument(after: "show", in: trimmed)?.lowercased() else { return false }
        return shownTopics.contains(topic)
    }

    /// The single bare word after a leading keyword, or nil when the line is ordinary JavaScript.
    private static func argument(after keyword: String, in statement: String) -> String? {
        guard statement.lowercased().hasPrefix(keyword + " ") else { return nil }
        let remainder = statement.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
        let word = remainder.hasSuffix(";") ? String(remainder.dropLast()) : remainder
        guard !word.isEmpty, !word.contains(where: { $0.isWhitespace }) else { return nil }
        guard !word.contains("("), !word.contains("="), !word.contains(".") else { return nil }
        return word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
    }
}
