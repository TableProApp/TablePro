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
import TableProSQLQuoting

public enum SnowflakeSQL {
    // Snowflake reads `\'` inside a literal as a content quote, so the backslash is escaped too.
    public static func escapeLiteral(_ value: String) -> String {
        SQLQuoting.stringLiteralBody(value, escapes: .backslash)
    }

    public static func quoteIdentifier(_ name: String) -> String {
        SQLQuoting.identifier(name)
    }

    // The LIKE layer first, escaped with a backslash, then the literal rule over the whole pattern.
    public static func escapeLikePattern(_ value: String) -> String {
        escapeLiteral(SQLQuoting.likePattern(value))
    }
}
