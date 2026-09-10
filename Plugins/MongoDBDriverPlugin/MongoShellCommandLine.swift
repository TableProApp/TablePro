import Foundation

/// Rewrites the two mongosh lines that are not JavaScript.
///
/// Kept in the plugin rather than shared through TableProPluginKit: a new public symbol there would
/// be missing from every already-shipped app, so the plugin would stop loading on the version most
/// users are running. The editor's own diagnostics recognise the same two lines through
/// `MongoShellCommandRecognizer`, which only has to know when *not* to report a syntax error.
///
/// `use orders` and `show collections` are shell syntax: mongosh reads them before the engine ever
/// sees them, and so does this. Everything else is left exactly as typed, so a statement that only
/// happens to start with the word `use` as an identifier is untouched.
enum MongoShellCommandLine {
    private static let shownTopics: Set<String> = [
        "dbs", "databases", "collections", "tables"
    ]

    static func rewrite(_ statement: String) -> String {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rewritten = useCommand(trimmed) ?? showCommand(trimmed) else { return statement }
        return rewritten
    }

    private static func useCommand(_ statement: String) -> String? {
        guard let name = argument(of: "use", in: statement), !name.isEmpty else { return nil }
        return "use(\(quoted(name)))"
    }

    private static func showCommand(_ statement: String) -> String? {
        guard let topic = argument(of: "show", in: statement)?.lowercased(),
              shownTopics.contains(topic) else { return nil }
        return "show(\(quoted(topic)))"
    }

    /// The single bare word after a leading keyword, or nil when the line is ordinary JavaScript.
    private static func argument(of keyword: String, in statement: String) -> String? {
        guard statement.lowercased().hasPrefix(keyword + " ") else { return nil }
        let remainder = statement.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
        let word = remainder.hasSuffix(";") ? String(remainder.dropLast()) : remainder
        guard !word.isEmpty, !word.contains(where: { $0.isWhitespace }) else { return nil }
        guard !word.contains("("), !word.contains("="), !word.contains(".") else { return nil }
        return word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
