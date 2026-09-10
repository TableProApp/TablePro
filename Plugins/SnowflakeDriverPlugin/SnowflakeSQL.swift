//
//  SnowflakeSQL.swift
//  SnowflakeDriverPlugin
//
//  The single owner of how a value or a name is spelled inside Snowflake SQL. Three copies of the
//  literal escaper and five of the identifier quoter used to sit in the files that build statements,
//  and nothing made them agree: one copy doubled the quote and forgot the backslash, which is all a
//  schema name needs to close the literal and run its own SQL.
//

import Foundation

public enum SnowflakeSQL {
    /// Snowflake reads `\'` inside a literal as a content quote, so doubling the quote alone leaves
    /// a backslash able to escape the very quote that was meant to close the value. The backslash
    /// goes first: doubling it after the quotes would also double the ones this method just added.
    public static func escapeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "''")
    }

    public static func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// `LIKE` reads `_` and `%` as wildcards, so a name containing either has to arrive escaped or
    /// it matches objects the caller never named.
    public static func escapeLikePattern(_ value: String) -> String {
        escapeLiteral(value)
            .replacingOccurrences(of: "_", with: "\\\\_")
            .replacingOccurrences(of: "%", with: "\\\\%")
    }
}
