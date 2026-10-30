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
        var result = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\", "_", "%": result.append("\\")
            default: break
            }
            result.append(scalar)
        }
        return String(result)
    }

    public static func unescapeDatabasePattern(_ value: String) -> String {
        var result = String.UnicodeScalarView()
        var isEscaped = false

        for scalar in value.unicodeScalars {
            if isEscaped {
                result.append(scalar)
                isEscaped = false
                continue
            }
            if scalar == "\\" {
                isEscaped = true
                continue
            }
            result.append(scalar)
        }

        if isEscaped {
            result.append("\\")
        }
        return String(result)
    }
}
