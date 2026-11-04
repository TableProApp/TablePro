import Foundation
import TableProSQLQuoting

public enum LibPQStringConformance {
    public static let parameterName = "standard_conforming_strings"

    public static let enableStatement = "SET standard_conforming_strings TO on"

    public static let showQuery = "SHOW standard_conforming_strings"

    public static func isOn(_ reportedValue: String?) -> Bool? {
        guard let reportedValue else { return nil }
        let normalized = reportedValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "on", "true", "yes", "1":
            return true
        case "off", "false", "no", "0":
            return false
        default:
            return nil
        }
    }

    public static func escape(_ value: String, standardConformingStrings: Bool) -> String {
        SQLQuoting.stringLiteralBody(withoutNUL(value), escapes: standardConformingStrings ? .standard : .backslash)
    }

    // PostgreSQL text cannot hold NUL, and `\0` in an escape string is refused, so it is dropped as libpq does.
    public static func withoutNUL(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { $0 != "\0" }))
    }
}
