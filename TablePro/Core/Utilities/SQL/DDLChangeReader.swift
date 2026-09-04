//
//  DDLChangeReader.swift
//  TablePro
//

import Foundation

/// What a DDL statement would add or remove, read well enough to show a reader before they approve
/// it.
///
/// Certainty or nothing. `DatabaseType` is open and every engine spells DDL its own way, so this
/// reads the handful of forms it can be sure about and returns no lines for anything else. The
/// caller shows the raw statement then, which is honest; a preview that missed a dropped column
/// would be worse than no preview at all. Nothing here gates execution: the gate is the approval
/// card and `confirm_destructive_operation`.
internal enum DDLChangeReader {
    private static let ddlKeywords: Set<String> = ["CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME", "COMMENT"]

    internal static func looksLikeDDL(_ sql: String) -> Bool {
        ddlKeywords.contains(QueryClassifier.leadingKeyword(of: sql))
    }

    internal static func preview(id: String, sql: String, databaseType: DatabaseType) -> SchemaChangePreview {
        let normalized = QueryClassifier.strippingLeadingComments(sql)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tier = QueryClassifier.classifyTier(sql, databaseType: databaseType)
        let words = Self.words(of: normalized)

        return SchemaChangePreview(
            id: id,
            sql: normalized,
            target: Self.target(words: words),
            lines: Self.lines(words: words, normalized: normalized, id: id),
            isDestructive: tier == .destructive
        )
    }

    /// The object the statement names, taken as the token after the object kind. Quoting styles vary
    /// by engine, so the identifier is unquoted rather than parsed.
    private static func target(words: [String]) -> String? {
        guard words.count >= 3 else { return nil }
        let objectKinds: Set<String> = [
            "TABLE", "VIEW", "INDEX", "SCHEMA", "DATABASE", "COLUMN", "TRIGGER", "FUNCTION", "SEQUENCE"
        ]
        for (offset, word) in words.enumerated() where objectKinds.contains(word.uppercased()) {
            let next = words.dropFirst(offset + 1).first { candidate in
                !["IF", "NOT", "EXISTS", "ONLY", "CONCURRENTLY"].contains(candidate.uppercased())
            }
            guard let next else { continue }
            return Self.unquoted(next)
        }
        return nil
    }

    private static func lines(words: [String], normalized: String, id: String) -> [SchemaChangeLine] {
        let keyword = QueryClassifier.leadingKeyword(of: normalized)
        switch keyword {
        case "CREATE":
            return Self.createLines(words: words, id: id)
        case "ALTER":
            return Self.alterLines(words: words, id: id)
        case "DROP":
            guard let object = Self.objectPhrase(words: words) else { return [] }
            return [SchemaChangeLine(id: "\(id).0", kind: .removes, text: object)]
        case "TRUNCATE":
            guard let target = Self.target(words: words) else { return [] }
            return [
                SchemaChangeLine(
                    id: "\(id).0",
                    kind: .removes,
                    text: String(format: String(localized: "Every row in %@"), target)
                )
            ]
        case "RENAME":
            return []
        default:
            return []
        }
    }

    private static func createLines(words: [String], id: String) -> [SchemaChangeLine] {
        guard let object = Self.objectPhrase(words: words) else { return [] }
        return [SchemaChangeLine(id: "\(id).0", kind: .adds, text: object)]
    }

    /// Only the `ADD`, `DROP` and `RENAME` clauses are read. An engine-specific clause leaves the
    /// list empty, which shows the raw statement rather than a partial account of it.
    private static func alterLines(words: [String], id: String) -> [SchemaChangeLine] {
        var lines: [SchemaChangeLine] = []
        var index = 0
        while index < words.count {
            let word = words[index].uppercased()
            let clause = ["ADD", "DROP", "RENAME"].contains(word) ? word : nil
            guard let clause else {
                index += 1
                continue
            }
            let rest = Array(words.dropFirst(index + 1))
            guard let phrase = Self.clausePhrase(rest) else {
                index += 1
                continue
            }
            lines.append(
                SchemaChangeLine(
                    id: "\(id).\(lines.count)",
                    kind: clause == "ADD" ? .adds : (clause == "DROP" ? .removes : .changes),
                    text: phrase
                )
            )
            index += 1
        }
        return lines
    }

    /// "COLUMN name" or "CONSTRAINT name", falling back to the bare identifier when the engine lets
    /// the object kind be implicit, which MySQL and SQLite both do for columns.
    private static func clausePhrase(_ rest: [String]) -> String? {
        let skippable: Set<String> = ["IF", "NOT", "EXISTS", "ONLY"]
        var remaining = rest.drop { skippable.contains($0.uppercased()) }
        guard let head = remaining.first else { return nil }
        let kinds: Set<String> = ["COLUMN", "CONSTRAINT", "INDEX", "KEY", "PRIMARY", "FOREIGN", "UNIQUE", "CHECK"]
        if kinds.contains(head.uppercased()) {
            remaining = remaining.dropFirst()
            let name = remaining.first { !skippable.contains($0.uppercased()) }
            guard let name else { return head.uppercased() }
            return "\(head.uppercased()) \(Self.unquoted(name))"
        }
        return String(format: String(localized: "COLUMN %@"), Self.unquoted(head))
    }

    private static func objectPhrase(words: [String]) -> String? {
        let objectKinds: Set<String> = [
            "TABLE", "VIEW", "INDEX", "SCHEMA", "DATABASE", "TRIGGER", "FUNCTION", "SEQUENCE"
        ]
        for (offset, word) in words.enumerated() where objectKinds.contains(word.uppercased()) {
            let next = words.dropFirst(offset + 1).first { candidate in
                !["IF", "NOT", "EXISTS", "ONLY", "CONCURRENTLY"].contains(candidate.uppercased())
            }
            guard let next else { continue }
            return "\(word.uppercased()) \(Self.unquoted(next))"
        }
        return nil
    }

    /// Tokens outside string literals, with the punctuation that separates a column list dropped.
    ///
    /// `QueryClassifier.strippingStringLiterals` is not reused here, because it treats a backtick or
    /// double-quoted run as a literal and removes it. That is the right call for classification,
    /// where a keyword hiding inside quotes must not lower a statement's tier, and the wrong one
    /// here: `` DROP TABLE `order items` `` would lose the only identifier the statement names. So
    /// a single-quoted run is dropped, a quoted identifier is kept whole as one token, and a keyword
    /// inside either is never mistaken for a clause.
    private static func words(of sql: String) -> [String] {
        var words: [String] = []
        var current = ""
        var characters = Array(sql)
        var index = 0

        func flush() {
            guard !current.isEmpty else { return }
            words.append(current)
            current = ""
        }

        while index < characters.count {
            let character = characters[index]
            switch character {
            case "'":
                flush()
                index = Self.skipQuoted(characters, from: index, quote: "'", capturing: nil)
            case "`", "\"", "[":
                flush()
                var identifier = ""
                index = Self.skipQuoted(
                    characters,
                    from: index,
                    quote: character == "[" ? "]" : character,
                    capturing: { identifier.append($0) }
                )
                words.append(identifier)
            case ",", "(", ")", ";":
                flush()
                index += 1
            default:
                if character.isWhitespace {
                    flush()
                } else {
                    current.append(character)
                }
                index += 1
            }
        }
        flush()
        return words
    }

    /// Walks past a quoted run and returns the index after its closing quote, handing each character
    /// inside to `capturing` when the caller wants the contents. An unterminated quote consumes the
    /// rest of the statement, which leaves the reader with too few tokens to be sure and so falls
    /// back to the raw SQL.
    private static func skipQuoted(
        _ characters: [Character],
        from start: Int,
        quote: Character,
        capturing: ((Character) -> Void)?
    ) -> Int {
        var index = start + 1
        while index < characters.count {
            if characters[index] == quote {
                if index + 1 < characters.count, characters[index + 1] == quote {
                    capturing?(quote)
                    index += 2
                    continue
                }
                return index + 1
            }
            capturing?(characters[index])
            index += 1
        }
        return index
    }

    private static func unquoted(_ identifier: String) -> String {
        identifier.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'[]"))
    }
}
