//
//  StructureCompareOptions.swift
//  TablePro
//
//  Normalization rules applied before two structures are considered different.
//  Every option defaults to ignoring the difference, because the metadata these
//  cover drifts between environments by design.
//

import Foundation

internal struct StructureCompareOptions: Codable, Hashable, Sendable {
    internal var ignoreIdentifierCase = true
    internal var ignoreColumnOrder = true
    internal var ignoreWhitespaceInText = true
    internal var ignoreAutoIncrementSeed = true
    internal var ignoreCollationAndCharset = true
    internal var ignoreCommentsAndOwners = true

    internal static let `default` = StructureCompareOptions()
}

internal extension StructureCompareOptions {
    func matchKey(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return ignoreIdentifierCase ? trimmed.lowercased() : trimmed
    }

    /// Two schemas of one database can hold the same table name, so the name alone cannot identify
    /// a table. Matching on it collapsed `public.users` and `audit.users` onto one result, diffed
    /// both against whichever target arrived first, and never reported the other as target-only.
    /// The schema joins the key only when both sides carry one, so a schemaless engine is
    /// unaffected.
    func matchKey(name: String, schema: String?) -> String {
        guard let schema, !schema.isEmpty else { return matchKey(name) }
        return "\(matchKey(schema))\u{1F}\(matchKey(name))"
    }

    func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        var result = value
        if ignoreAutoIncrementSeed {
            result = Self.autoIncrementSeed.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "AUTO_INCREMENT"
            )
        }
        if ignoreWhitespaceInText {
            result = Self.whitespaceRun.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: " "
            )
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result.isEmpty ? nil : result
    }

    func normalizedType(_ dataType: String) -> String {
        let collapsed = Self.whitespaceRun.stringByReplacingMatches(
            in: dataType,
            range: NSRange(dataType.startIndex..., in: dataType),
            withTemplate: " "
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func columnListKey(_ columns: [String]) -> String {
        columns.map { matchKey($0) }.joined(separator: "\u{1F}")
    }

    private static let whitespaceRun = makeRegex("\\s+")
    private static let autoIncrementSeed = makeRegex("(?i)AUTO_INCREMENT\\s*=\\s*\\d+")

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("StructureCompareOptions pattern failed to compile: \(pattern)")
        }
        return regex
    }
}
