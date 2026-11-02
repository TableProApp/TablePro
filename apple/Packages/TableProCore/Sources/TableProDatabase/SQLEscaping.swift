import Foundation
import TableProSQLQuoting

public enum SQLEscaping {
    public static func ansiStringLiteral(_ value: String) -> String {
        SQLQuoting.stringLiteralBody(value, escapes: .standard)
    }

    public static func backslashStringLiteral(_ value: String) -> String {
        SQLQuoting.stringLiteralBody(value, escapes: .mysql)
    }
}
