//
//  MySQLGrantParser.swift
//  MySQLDriverPlugin
//
//  Parses SHOW GRANTS output, the only authoritative source for a MySQL account's
//  privileges. The mysql.user boolean columns miss dynamic privileges entirely.
//

import Foundation

public struct MySQLParsedPrivilege: Equatable, Sendable {
    public let name: String
    public let columns: [String]

    public init(name: String, columns: [String] = []) {
        self.name = name
        self.columns = columns
    }
}

public struct MySQLParsedGrant: Equatable, Sendable {
    public let privileges: [MySQLParsedPrivilege]
    public let scope: PluginPrivilegeScope
    public let isGrantable: Bool

    public var privilegeNames: [String] { privileges.map(\.name) }
    public var isColumnScoped: Bool { privileges.contains { !$0.columns.isEmpty } }
}

public enum MySQLGrantParser {
    public static let allPrivileges = "ALL PRIVILEGES"

    public static func parseGrant(_ line: String) -> MySQLParsedGrant? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let afterGrant = dropKeyword("GRANT", from: trimmed) else { return nil }
        guard let onRange = rangeOfKeyword("ON", in: afterGrant) else { return nil }

        let privilegeText = String(afterGrant[afterGrant.startIndex..<onRange.lowerBound])
        let remainder = String(afterGrant[onRange.upperBound...])
        guard let toRange = rangeOfKeyword("TO", in: remainder) else { return nil }

        let targetText = String(remainder[remainder.startIndex..<toRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let granteeText = String(remainder[toRange.upperBound...])

        guard let scope = parseScope(targetText) else { return nil }

        let privileges = splitTopLevel(privilegeText, separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap(normalizePrivilege)
        guard !privileges.isEmpty else { return nil }

        return MySQLParsedGrant(
            privileges: privileges,
            scope: scope,
            isGrantable: hasGrantOption(granteeText)
        )
    }

    public static func parseRoleGrant(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let afterGrant = dropKeyword("GRANT", from: trimmed) else { return nil }
        guard rangeOfKeyword("ON", in: afterGrant) == nil else { return nil }
        guard let toRange = rangeOfKeyword("TO", in: afterGrant) else { return nil }

        let roleText = String(afterGrant[afterGrant.startIndex..<toRange.lowerBound])
        let roles = splitTopLevel(roleText, separator: ",").compactMap { entry -> String? in
            let name = splitTopLevel(entry.trimmingCharacters(in: .whitespaces), separator: "@").first
            guard let name else { return nil }
            let unquoted = unquoteIdentifier(name.trimmingCharacters(in: .whitespaces))
            return unquoted.isEmpty ? nil : unquoted
        }
        return roles.isEmpty ? nil : roles
    }

    private static func normalizePrivilege(_ raw: String) -> MySQLParsedPrivilege? {
        let collapsed = raw.prefix { $0 != "(" }
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard let name = PluginPrivilegeName.sanitized(collapsed) else { return nil }

        return MySQLParsedPrivilege(name: name, columns: parseColumnList(raw))
    }

    private static func parseColumnList(_ raw: String) -> [String] {
        guard let open = raw.firstIndex(of: "("), let close = raw.lastIndex(of: ")"), open < close else {
            return []
        }
        let inner = String(raw[raw.index(after: open)..<close])
        return splitTopLevel(inner, separator: ",").map {
            unquoteIdentifier($0.trimmingCharacters(in: .whitespaces))
        }
        .filter { !$0.isEmpty }
    }

    private static func parseScope(_ target: String) -> PluginPrivilegeScope? {
        let parts = splitTopLevel(target, separator: ".")
        guard parts.count == 2 else { return nil }

        let databasePart = parts[0].trimmingCharacters(in: .whitespaces)
        let objectPart = parts[1].trimmingCharacters(in: .whitespaces)

        if databasePart == "*" {
            return objectPart == "*" ? .server : nil
        }

        let quotedDatabase = unquoteIdentifier(databasePart)
        guard !quotedDatabase.isEmpty else { return nil }

        // Only a database-level target carries a LIKE pattern. A table-level target's database name
        // is a literal identifier and must not be unescaped, or a name containing a backslash is
        // silently rewritten.
        if objectPart == "*" {
            return .database(
                MySQLGrantPatternEscaping.unescapeDatabasePattern(quotedDatabase)
            )
        }

        let table = unquoteIdentifier(objectPart)
        guard !table.isEmpty else { return nil }
        return .table(database: quotedDatabase, schema: nil, table: table)
    }

    private static func hasGrantOption(_ granteeText: String) -> Bool {
        granteeText.uppercased().contains("WITH GRANT OPTION")
    }

    public static func unquoteIdentifier(_ value: String) -> String {
        guard let first = value.first, let last = value.last, value.count >= 2 else { return value }
        guard first == last, first == "`" || first == "'" || first == "\"" else { return value }

        let inner = String(value.dropFirst().dropLast())
        return inner.replacingOccurrences(of: String(repeating: String(first), count: 2), with: String(first))
    }

    private static func dropKeyword(_ keyword: String, from text: String) -> String? {
        guard let range = rangeOfKeyword(keyword, in: text), range.lowerBound == text.startIndex else {
            return nil
        }
        return String(text[range.upperBound...])
    }

    private static func rangeOfKeyword(_ keyword: String, in text: String) -> Range<String.Index>? {
        let scalars = Array(text)
        let target = Array(keyword.uppercased())
        var quote: Character?
        var depth = 0
        var index = 0

        while index < scalars.count {
            let character = scalars[index]

            if let active = quote {
                if character == active {
                    quote = nil
                }
                index += 1
                continue
            }
            if character == "`" || character == "'" || character == "\"" {
                quote = character
                index += 1
                continue
            }
            if character == "(" {
                depth += 1
                index += 1
                continue
            }
            if character == ")" {
                depth = max(0, depth - 1)
                index += 1
                continue
            }
            guard depth == 0, isBoundary(scalars, at: index - 1) else {
                index += 1
                continue
            }

            let end = index + target.count
            guard end <= scalars.count else {
                index += 1
                continue
            }
            let candidate = scalars[index..<end].map { Character($0.uppercased()) }
            guard candidate == target, isBoundary(scalars, at: end) else {
                index += 1
                continue
            }

            let lower = text.index(text.startIndex, offsetBy: index)
            let upper = text.index(text.startIndex, offsetBy: end)
            return lower..<upper
        }
        return nil
    }

    private static func isBoundary(_ scalars: [Character], at index: Int) -> Bool {
        guard index >= 0, index < scalars.count else { return true }
        return scalars[index] == " " || scalars[index] == "\t"
    }

    private static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var depth = 0

        for character in text {
            if let active = quote {
                current.append(character)
                if character == active {
                    quote = nil
                }
                continue
            }
            switch character {
            case "`", "'", "\"":
                quote = character
                current.append(character)
            case "(":
                depth += 1
                current.append(character)
            case ")":
                depth = max(0, depth - 1)
                current.append(character)
            case separator where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current)
        return parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
