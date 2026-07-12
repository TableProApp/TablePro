//
//  MySQLGrantParser.swift
//  MySQLDriverPlugin
//
//  Parses SHOW GRANTS output, the only authoritative source for a MySQL account's
//  privileges. The mysql.user boolean columns miss dynamic privileges entirely.
//

import Foundation

public struct MySQLParsedGrant: Equatable, Sendable {
    public let privileges: [String]
    public let scope: PluginPrivilegeScope
    public let isGrantable: Bool
    public let isColumnScoped: Bool
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

        let parsedPrivileges = splitTopLevel(privilegeText, separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let isColumnScoped = parsedPrivileges.contains { $0.contains("(") }
        let privileges = parsedPrivileges.compactMap(normalizePrivilege)
        guard !privileges.isEmpty else { return nil }

        return MySQLParsedGrant(
            privileges: privileges,
            scope: scope,
            isGrantable: hasGrantOption(granteeText),
            isColumnScoped: isColumnScoped
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

    private static func normalizePrivilege(_ raw: String) -> String? {
        let withoutColumns = raw.prefix { $0 != "(" }
        let collapsed = withoutColumns
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return PluginPrivilegeName.sanitized(collapsed)
    }

    private static func parseScope(_ target: String) -> PluginPrivilegeScope? {
        let parts = splitTopLevel(target, separator: ".")
        guard parts.count == 2 else { return nil }

        let databasePart = parts[0].trimmingCharacters(in: .whitespaces)
        let objectPart = parts[1].trimmingCharacters(in: .whitespaces)

        if databasePart == "*" {
            return objectPart == "*" ? .server : nil
        }

        let database = MySQLGrantPatternEscaping.unescapeDatabasePattern(
            unquoteIdentifier(databasePart)
        )
        guard !database.isEmpty else { return nil }

        if objectPart == "*" {
            return .database(database)
        }

        let table = unquoteIdentifier(objectPart)
        guard !table.isEmpty else { return nil }
        return .table(database: database, schema: nil, table: table)
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
