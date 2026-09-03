//
//  PluginExportRowScope.swift
//  TableProPluginKit
//

import Foundation

/// Which rows and columns of one object an export writes.
///
/// Empty means the whole object, which is what every export did before this existed and what an
/// export still does unless the user narrows it.
public struct PluginExportRowScope: Sendable, Equatable, Codable {
    /// A `WHERE` expression without the keyword, in the engine's own dialect.
    public let filter: String

    /// The most rows to write, or nil for all of them.
    public let rowLimit: Int?

    /// The columns to write, in the order given, or empty for all of them.
    public let columns: [String]

    public init(filter: String = "", rowLimit: Int? = nil, columns: [String] = []) {
        self.filter = filter
        self.rowLimit = rowLimit
        self.columns = columns
    }

    public static let unrestricted = PluginExportRowScope()

    public var isUnrestricted: Bool {
        sanitizedFilter.isEmpty && rowLimit == nil && columns.isEmpty
    }

    /// The filter with its statement terminator removed.
    ///
    /// The text is the user's own SQL against their own connection, so it is not sanitized in the
    /// injection sense. What it must not do is smuggle a second statement into a query the export
    /// builds: a trailing `;` alone is a typing habit and is dropped, and a `;` anywhere else means
    /// the text is not the single expression this field is for, so it is refused outright rather
    /// than being run as two statements.
    public var sanitizedFilter: String {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let withoutTerminator = trimmed.hasSuffix(";")
            ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmed
        guard !withoutTerminator.contains(";") else { return "" }
        return withoutTerminator
    }

    /// Whether the filter carries text the sanitizer refused, so a caller can say so rather than
    /// silently exporting every row of a table the user meant to narrow.
    public var hasRejectedFilter: Bool {
        !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sanitizedFilter.isEmpty
    }

    /// A one-line description for the export tree and the dump's own comments.
    public var summary: String {
        var parts: [String] = []
        if !columns.isEmpty { parts.append("\(columns.count) columns") }
        if !sanitizedFilter.isEmpty { parts.append("WHERE \(sanitizedFilter)") }
        if let rowLimit { parts.append("LIMIT \(rowLimit)") }
        return parts.joined(separator: ", ")
    }
}
