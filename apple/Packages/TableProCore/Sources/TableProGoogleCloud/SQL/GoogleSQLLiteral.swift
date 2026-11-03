import Foundation
import TableProSQLQuoting

public enum GoogleSQLLiteral {
    public static func quotedString(_ value: String) -> String {
        SQLQuoting.stringLiteral(value, escapes: .googleSQL)
    }

    public static func escapedStringBody(_ value: String) -> String {
        SQLQuoting.stringLiteralBody(value, escapes: .googleSQL)
    }

    // GoogleSQL reads the string escapes inside a backquoted name too.
    public static func quotedIdentifier(_ name: String) -> String {
        "`" + SQLQuoting.stringLiteralBody(name, escapes: .googleSQL) + "`"
    }

    public static func bytesLiteral(_ data: Data) -> String {
        "FROM_BASE64('" + data.base64EncodedString() + "')"
    }

    public static func likePatternBody(_ value: String) -> String {
        SQLQuoting.likePattern(value)
    }
}
