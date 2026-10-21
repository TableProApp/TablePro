//
//  ClickHouseTableOperations.swift
//  ClickHouseDriverPlugin
//

import Foundation

nonisolated func clickHouseTableType(forEngine engine: String?) -> String {
    switch engine {
    case "MaterializedView":
        return "MATERIALIZED VIEW"
    case "View", "LiveView", "WindowView":
        return "VIEW"
    default:
        return "TABLE"
    }
}

/// ClickHouse reads backslash escapes inside a backquoted name, so the backslash is doubled first or
/// `\`` would end the name early. `.literal` matches by code unit, so a combining mark after a
/// backquote cannot hide it from the replacement.
nonisolated func clickHouseQuotedIdentifier(_ name: String) -> String {
    let escaped = name
        .replacingOccurrences(of: "\\", with: "\\\\", options: .literal)
        .replacingOccurrences(of: "`", with: "``", options: .literal)
    return "`\(escaped)`"
}

nonisolated func clickHouseDropObjectStatement(name: String, objectType: String) -> String? {
    guard objectType == "MATERIALIZED VIEW" else { return nil }
    return "DROP VIEW \(clickHouseQuotedIdentifier(name))"
}

nonisolated func clickHouseCommentStatement(
    name: String,
    database: String?,
    objectType: String,
    comment: String?,
    profile: ClickHouseServerProfile
) -> String? {
    guard profile.hasModifyComment, objectType.uppercased() == "TABLE" else { return nil }
    let table = database.flatMap {
        $0.isEmpty ? nil : "\(clickHouseQuotedIdentifier($0)).\(clickHouseQuotedIdentifier(name))"
    } ?? clickHouseQuotedIdentifier(name)
    return "ALTER TABLE \(table) MODIFY COMMENT '\(ClickHousePluginDriver.escapeStringLiteral(comment ?? ""))'"
}
