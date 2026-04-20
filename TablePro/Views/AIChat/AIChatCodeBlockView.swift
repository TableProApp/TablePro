//
//  AIChatCodeBlockView.swift
//  TablePro
//
//  Code block view with copy and insert-to-editor actions.
//

import AppKit
import SwiftUI

/// Displays a code block from AI response with action buttons
struct AIChatCodeBlockView: View {
    let code: String
    let language: String?

    @State private var isCopied: Bool = false
    @FocusedValue(\.commandActions) private var actions

    var body: some View {
        GroupBox {
            codeContent
        } label: {
            codeBlockHeader
        }
        .groupBoxStyle(CodeBlockGroupBoxStyle())
    }

    private var codeBlockHeader: some View {
        HStack {
            if let language {
                Text(language.uppercased())
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .separatorColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Spacer()

            Button {
                ClipboardService.shared.writeText(code)
                isCopied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    isCopied = false
                }
            } label: {
                Label(
                    isCopied ? String(localized: "Copied") : String(localized: "Copy"),
                    systemImage: isCopied ? "checkmark" : "doc.on.doc"
                )
                .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if isInsertable {
                Button {
                    actions?.insertQueryFromAI(code)
                } label: {
                    Label(String(localized: "Insert"), systemImage: "square.and.pencil")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(actions == nil)
                .help(actions == nil
                    ? String(localized: "Focus the query editor to insert")
                    : String(localized: "Insert into editor"))
            }
        }
    }

    private var codeContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            if isSQL {
                Text(highlightedSQL(code))
                    .textSelection(.enabled)
                    .padding(10)
            } else if isMongoDB {
                Text(highlightedJavaScript(code))
                    .textSelection(.enabled)
                    .padding(10)
            } else if isRedis {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            } else {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
    }

    private var isSQL: Bool {
        guard let language else { return false }
        let sqlLanguages = ["sql", "mysql", "postgresql", "postgres", "sqlite"]
        return sqlLanguages.contains(language.lowercased())
    }

    private var isMongoDB: Bool {
        guard let language else { return false }
        let mongoLanguages = ["javascript", "js", "mongodb", "mongo"]
        return mongoLanguages.contains(language.lowercased())
    }

    private var isRedis: Bool {
        guard let language else { return false }
        let redisLanguages = ["redis", "bash", "shell", "sh"]
        return redisLanguages.contains(language.lowercased())
    }

    private var isInsertable: Bool {
        isSQL || isMongoDB || isRedis
    }

    // MARK: - Static SQL Regex Patterns (compiled once)

    private enum SQLPatterns {
        // swiftlint:disable force_try
        static let singleLineComment = try! NSRegularExpression(pattern: "--[^\r\n]*")
        static let multiLineComment = try! NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/")
        static let stringLiteral = try! NSRegularExpression(pattern: "'[^']*'")
        static let number = try! NSRegularExpression(pattern: "\\b\\d+(\\.\\d+)?\\b")
        static let nullBoolLiteral = try! NSRegularExpression(
            pattern: "\\b(NULL|TRUE|FALSE)\\b",
            options: .caseInsensitive
        )
        static let keyword: NSRegularExpression = {
            let keywords = [
                "SELECT", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "CROSS",
                "ON", "AND", "OR", "NOT", "IN", "EXISTS", "BETWEEN", "LIKE", "IS", "AS",
                "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "UNION", "ALL", "DISTINCT",
                "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "ALTER", "DROP",
                "TABLE", "INDEX", "VIEW", "IF", "THEN", "ELSE", "END", "CASE", "WHEN",
                "COUNT", "SUM", "AVG", "MIN", "MAX", "ASC", "DESC",
                "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "DEFAULT", "CONSTRAINT", "UNIQUE",
                "CHECK", "CASCADE", "TRUNCATE", "RETURNING", "WITH", "RECURSIVE",
                "OVER", "PARTITION", "WINDOW", "GRANT", "REVOKE",
                "BEGIN", "COMMIT", "ROLLBACK", "EXPLAIN", "ANALYZE"
            ]
            let pattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
            return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        }()
        // swiftlint:enable force_try
    }

    /// Shared highlighting engine: applies regex-based coloring with protected ranges and a 10k char cap.
    private static func highlightCode(
        _ code: String,
        protectedPatterns: [(NSRegularExpression, NSColor)],
        unprotectedPatterns: [(NSRegularExpression, NSColor)]
    ) -> AttributedString {
        var result = AttributedString(code)
        result.font = .system(size: 12, design: .monospaced)

        var protectedRanges: [Range<AttributedString.Index>] = []

        let nsCode = code as NSString
        let maxHighlightLength = 10_000
        let highlightRange = NSRange(
            location: 0,
            length: min(nsCode.length, maxHighlightLength)
        )

        func applyColor(_ nsRange: NSRange, color: NSColor, protect: Bool) {
            guard let stringRange = Range(nsRange, in: code),
                  let attrStart = AttributedString.Index(stringRange.lowerBound, within: result),
                  let attrEnd = AttributedString.Index(stringRange.upperBound, within: result)
            else { return }
            let range = attrStart..<attrEnd
            result[range].foregroundColor = Color(nsColor: color)
            if protect {
                protectedRanges.append(range)
            }
        }

        func isProtected(_ nsRange: NSRange) -> Bool {
            guard let stringRange = Range(nsRange, in: code),
                  let attrStart = AttributedString.Index(stringRange.lowerBound, within: result),
                  let attrEnd = AttributedString.Index(stringRange.upperBound, within: result)
            else { return false }
            let range = attrStart..<attrEnd
            return protectedRanges.contains { $0.overlaps(range) }
        }

        for (regex, color) in protectedPatterns {
            for match in regex.matches(in: code, range: highlightRange) {
                applyColor(match.range, color: color, protect: true)
            }
        }

        for (regex, color) in unprotectedPatterns {
            for match in regex.matches(in: code, range: highlightRange) {
                guard !isProtected(match.range) else { continue }
                applyColor(match.range, color: color, protect: false)
            }
        }

        return result
    }

    private func highlightedSQL(_ code: String) -> AttributedString {
        Self.highlightCode(
            code,
            protectedPatterns: [
                (SQLPatterns.singleLineComment, .systemGreen),
                (SQLPatterns.multiLineComment, .systemGreen),
                (SQLPatterns.stringLiteral, .systemRed)
            ],
            unprotectedPatterns: [
                (SQLPatterns.number, .systemPurple),
                (SQLPatterns.nullBoolLiteral, .systemOrange),
                (SQLPatterns.keyword, .systemBlue)
            ]
        )
    }

    // MARK: - Static JavaScript Regex Patterns (compiled once)

    private enum JSPatterns {
        // swiftlint:disable force_try
        static let singleLineComment = try! NSRegularExpression(pattern: "//[^\r\n]*")
        static let multiLineComment = try! NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/")
        static let doubleQuoteString = try! NSRegularExpression(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"")
        static let singleQuoteString = try! NSRegularExpression(pattern: "'(?:[^'\\\\]|\\\\.)*'")
        static let number = try! NSRegularExpression(pattern: "\\b\\d+(\\.\\d+)?\\b")
        static let boolNull = try! NSRegularExpression(
            pattern: "\\b(true|false|null|undefined|NaN|Infinity)\\b"
        )
        static let keyword: NSRegularExpression = {
            let keywords = [
                "var", "let", "const", "function", "return", "if", "else", "for", "while",
                "do", "switch", "case", "break", "continue", "new", "this", "typeof",
                "instanceof", "in", "of", "try", "catch", "throw", "finally", "async", "await"
            ]
            let pattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
            return try! NSRegularExpression(pattern: pattern)
        }()
        static let method: NSRegularExpression = {
            let methods = [
                "find", "findOne", "insertOne", "insertMany", "updateOne", "updateMany",
                "deleteOne", "deleteMany", "aggregate", "countDocuments", "distinct",
                "createIndex", "dropIndex", "explain", "limit", "skip", "sort", "project",
                "match", "group", "unwind", "lookup", "replaceOne", "bulkWrite"
            ]
            let pattern = "\\.(" + methods.joined(separator: "|") + ")\\b"
            return try! NSRegularExpression(pattern: pattern)
        }()
        static let property = try! NSRegularExpression(pattern: "\\b(db)\\b")
        // swiftlint:enable force_try
    }

    private func highlightedJavaScript(_ code: String) -> AttributedString {
        Self.highlightCode(
            code,
            protectedPatterns: [
                (JSPatterns.singleLineComment, .systemGreen),
                (JSPatterns.multiLineComment, .systemGreen),
                (JSPatterns.doubleQuoteString, .systemRed),
                (JSPatterns.singleQuoteString, .systemRed)
            ],
            unprotectedPatterns: [
                (JSPatterns.number, .systemPurple),
                (JSPatterns.boolNull, .systemOrange),
                (JSPatterns.keyword, .systemPink),
                (JSPatterns.method, .systemBlue),
                (JSPatterns.property, .systemTeal)
            ]
        )
    }
}

// MARK: - Code Block GroupBox Style

private struct CodeBlockGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            configuration.label
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            Divider()

            configuration.content
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}
