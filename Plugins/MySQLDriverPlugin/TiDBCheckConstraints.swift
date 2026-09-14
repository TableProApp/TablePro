//
//  TiDBCheckConstraints.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal enum TiDBCheckConstraints {
    static func parse(createTable sql: String) -> [PluginCheckConstraintInfo] {
        guard let body = MySQLCreateTableScanner.firstGroup(in: Substring(sql)) else { return [] }
        return MySQLCreateTableScanner.topLevelElements(of: body).compactMap(checkConstraint(in:))
    }

    private static func checkConstraint(in element: Substring) -> PluginCheckConstraintInfo? {
        var rest = element
        guard MySQLCreateTableScanner.consume("CONSTRAINT", from: &rest),
              let name = MySQLCreateTableScanner.consumeBacktickName(from: &rest),
              MySQLCreateTableScanner.consume("CHECK", from: &rest)
        else { return nil }
        rest = rest.drop(while: \.isWhitespace)
        guard rest.first == "(", let expression = MySQLCreateTableScanner.firstGroup(in: rest) else { return nil }
        return PluginCheckConstraintInfo(name: name, expression: expression.trimmingCharacters(in: .whitespaces))
    }
}
