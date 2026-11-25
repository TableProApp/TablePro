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

    // Two schemas of one listing can hold the same name, so another schema joins the key. The schema the side was
    // listed from does not: SQL Server spells it on every table, and `dbo.users` has to pair with `staging.users`.
    func matchKey(name: String, schema: String?, listedIn listedSchema: String? = nil) -> String {
        guard let schema, !schema.isEmpty else { return matchKey(name) }
        if let listedSchema, matchKey(listedSchema) == matchKey(schema) { return matchKey(name) }
        return "\(matchKey(schema))\u{1F}\(matchKey(name))"
    }

    // The endpoint's schema, or with none the one schema its listing carries: a listing is one schema, the session's own.
    static func listedSchema(endpoint: String?, tableSchemas: [String?]) -> String? {
        if let endpoint, !endpoint.isEmpty { return endpoint }
        let carried = Set(tableSchemas.compactMap { $0 }.filter { !$0.isEmpty })
        return carried.count == 1 ? carried.first : nil
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

    /// Without the schema a type names, so a type both sides declare reads the same whether the
    /// side that read it resolved it on its own path or qualified it: `public.geometry(Point,4326)`
    /// against `extensions.geometry(Point,4326)`, and a type in one schema read from another.
    func normalizedType(_ dataType: String) -> String {
        let collapsed = Self.whitespaceRun.stringByReplacingMatches(
            in: dataType,
            range: NSRange(dataType.startIndex..., in: dataType),
            withTemplate: " "
        )
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return SchemaRelativeSpelling.unqualified(trimmed).lowercased()
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
