//
//  SQLBoundaryValidator.swift
//  TablePro
//

import Foundation

enum SQLBoundaryValidator {
    private static let destructiveStatementPattern: NSRegularExpression? = {
        let keywords = "DROP|DELETE|INSERT|UPDATE|ALTER|CREATE|TRUNCATE|GRANT|REVOKE|EXEC|EXECUTE"
        let pattern = ";\\s*(\(keywords))\\b"
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static let commentInjectionPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "(?:^|\\s)--|\\/\\*", options: [])
    }()

    static func isRawFilterConditionSafe(_ sql: String) -> Bool {
        let range = NSRange(sql.startIndex..., in: sql)

        if let pattern = destructiveStatementPattern,
           pattern.firstMatch(in: sql, range: range) != nil {
            return false
        }

        if let pattern = commentInjectionPattern,
           pattern.firstMatch(in: sql, range: range) != nil {
            return false
        }

        return true
    }
}
