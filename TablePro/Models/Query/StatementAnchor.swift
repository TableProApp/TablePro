//
//  StatementAnchor.swift
//  TablePro
//
//  Where in the editor a result came from, kept so the result can point back at it.
//

import Foundation
import TableProPluginKit

/// The statement a result set was produced by, as something that can be found again.
///
/// A bare offset is not enough. The reader can edit the query after running it, and every edit above a statement
/// moves it, so a stored offset would send the caret into whatever text has since taken that place. The anchor
/// therefore carries a fingerprint as well and is always re-resolved against the document as it is now.
///
/// The fingerprint is a bounded prefix rather than the whole statement, because a SQL dump can hold a single
/// statement millions of characters long and this is stored per result set. The prefix doubles as the result's
/// label, so the same bounded copy serves both and neither has to keep the full text.
struct StatementAnchor: Equatable {
    /// How much of the statement is kept, in UTF-16 units.
    static let previewLimit = 120

    /// The span the statement occupied when it ran.
    let range: NSRange

    /// The statement's leading characters, capped at ``previewLimit``.
    let preview: String

    init(range: NSRange, preview: String) {
        self.range = range
        self.preview = preview
    }

    init(_ statement: SQLStatementScanner.ExecutableStatement) {
        self.init(range: statement.range, preview: Self.preview(of: statement.sql))
    }

    /// A short name for the statement, for a result that has no table name to be called after.
    ///
    /// A leading line comment wins, because a reader who wrote one has already named the statement better than its
    /// first clause ever could. Otherwise the statement's own opening stands in, whitespace collapsed so a query
    /// written across several lines still reads as one label.
    var label: String {
        let parts = Self.split(preview)
        let source = parts.comment ?? parts.statement
        let collapsed = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return "" }

        let text = collapsed as NSString
        guard text.length > Self.labelLimit else { return collapsed }
        return text.substring(to: Self.labelLimit).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let labelLimit = 28

    /// Separates the line comments a statement opens with from the statement itself.
    ///
    /// A `--` with nothing after it names nothing, so it is dropped from both halves rather than being handed back as
    /// a name or left sitting in front of the SQL.
    private static func split(_ preview: String) -> (comment: String?, statement: String) {
        var comments: [String] = []
        var lines = preview.split(separator: "\n", omittingEmptySubsequences: false)[...]

        while let line = lines.first {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("--") else { break }
            let body = trimmed.drop(while: { $0 == "-" }).trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { comments.append(body) }
            lines = lines.dropFirst()
        }

        return (
            comments.isEmpty ? nil : comments.joined(separator: " "),
            lines.joined(separator: "\n")
        )
    }

    static func preview(of sql: String) -> String {
        let text = sql as NSString
        guard text.length > previewLimit else { return sql }
        return text.substring(to: previewLimit)
    }

    /// Where this statement sits in `query` now, or `nil` when it is no longer there.
    ///
    /// Resolution is against a fresh scan rather than a search through the raw text: the scan is what decides where
    /// statements begin in the first place, and matching whole statements keeps a fingerprint from landing inside a
    /// string literal or a comment that happens to start the same way.
    func resolve(
        in query: String,
        model: QueryStatementModel = .sql,
        dialect: SqlDialect = .generic
    ) -> NSRange? {
        let statements = QueryStatementScanner.executableStatements(
            in: query, model: model, dialect: dialect
        )

        if let exact = statements.first(where: { $0.range == range && matches($0) }) {
            return exact.range
        }

        /// An edit above the statement moves it without changing it. Among equally good candidates the nearest one
        /// wins, because a reader who inserted a line expects the statement they ran, not another copy of it
        /// elsewhere in the script.
        return statements
            .filter { matches($0) }
            .min { lhs, rhs in
                abs(lhs.range.location - range.location) < abs(rhs.range.location - range.location)
            }?
            .range
    }

    private func matches(_ statement: SQLStatementScanner.ExecutableStatement) -> Bool {
        statement.range.length == range.length && Self.preview(of: statement.sql) == preview
    }
}
