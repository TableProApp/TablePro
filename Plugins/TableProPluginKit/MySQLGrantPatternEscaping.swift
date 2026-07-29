//
//  MySQLGrantPatternEscaping.swift
//  MySQLDriverPlugin
//
//  In a MySQL GRANT, the database-name position is a LIKE pattern: `_` and `%` are
//  wildcards unless backslash-escaped. Escaping here is therefore distinct from, and
//  applied before, backtick identifier quoting.
//

import Foundation

public enum MySQLGrantPatternEscaping {
    public static func escapeDatabasePattern(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "\\", "_", "%":
                result.append("\\")
                result.append(character)
            default:
                result.append(character)
            }
        }
        return result
    }

    public static func unescapeDatabasePattern(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        var isEscaped = false

        for character in value {
            if isEscaped {
                result.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            result.append(character)
        }

        if isEscaped {
            result.append("\\")
        }
        return result
    }
}
