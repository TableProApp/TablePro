//
//  SQLParameterInliner.swift
//  TablePro
//
//  Utility for inlining parameter values into parameterized SQL strings.
//  Used for display/preview purposes only — actual execution uses prepared statements.
//

import Foundation
import TableProPluginKit

struct SQLParameterInliner {
    // MARK: - Public API

    /// Inlines parameter values into a parameterized SQL string for display purposes.
    ///
    /// - Parameters:
    ///   - statement: The parameterized statement containing SQL with placeholders and bound values.
    ///   - databaseType: The database type, which determines placeholder style (`?` vs `$N`).
    /// - Returns: A SQL string with placeholders replaced by formatted literal values.
    static func inline(_ statement: ParameterizedStatement, databaseType: DatabaseType) -> String {
        let style = PluginMetadataRegistry.shared.snapshot(forTypeId: databaseType.pluginTypeId)?.parameterStyle ?? .questionMark
        if style == .dollar {
            return inlineDollarPlaceholders(statement.sql, parameters: statement.parameters)
        } else {
            return inlineQuestionMarkPlaceholders(statement.sql, parameters: statement.parameters)
        }
    }

    // MARK: - Private Helpers

    /// Replaces `?` placeholders sequentially with formatted parameter values.
    /// Skips `?` characters inside single-quoted SQL string literals.
    private static func inlineQuestionMarkPlaceholders(_ sql: String, parameters: [Any?]) -> String {
        var result = ""
        var paramIndex = 0
        var inString = false
        var previousWasQuote = false
        let nsSQL = sql as NSString
        let length = nsSQL.length
        var i = 0
        var rangeStart = 0

        let questionMark = UInt16(UnicodeScalar("?").value)
        let singleQuote = UInt16(UnicodeScalar("'").value)

        while i < length {
            let ch = nsSQL.character(at: i)

            if ch == singleQuote {
                if inString {
                    if previousWasQuote {
                        previousWasQuote = false
                    } else {
                        previousWasQuote = true
                    }
                } else {
                    inString = true
                    previousWasQuote = false
                }
                i += 1
            } else {
                if previousWasQuote {
                    inString = false
                    previousWasQuote = false
                }
                if ch == questionMark && !inString && paramIndex < parameters.count {
                    // Flush accumulated characters before the placeholder
                    if rangeStart < i {
                        result += nsSQL.substring(with: NSRange(location: rangeStart, length: i - rangeStart))
                    }
                    result += formatValue(parameters[paramIndex])
                    paramIndex += 1
                    i += 1
                    rangeStart = i
                } else {
                    i += 1
                }
            }
        }

        // Flush remaining characters
        if rangeStart < length {
            result += nsSQL.substring(with: NSRange(location: rangeStart, length: length - rangeStart))
        }

        return result
    }

    /// Replaces `$1`, `$2`, ... placeholders with formatted parameter values.
    /// Skips `$N` sequences inside single-quoted SQL string literals.
    private static func inlineDollarPlaceholders(_ sql: String, parameters: [Any?]) -> String {
        var result = ""
        var inString = false
        var previousWasQuote = false
        let nsSQL = sql as NSString
        let length = nsSQL.length
        var i = 0
        var rangeStart = 0

        let dollarChar = UInt16(UnicodeScalar("$").value)
        let singleQuote = UInt16(UnicodeScalar("'").value)

        while i < length {
            let ch = nsSQL.character(at: i)

            if ch == singleQuote {
                if inString {
                    if previousWasQuote {
                        previousWasQuote = false
                    } else {
                        previousWasQuote = true
                    }
                } else {
                    inString = true
                    previousWasQuote = false
                }
                i += 1
            } else {
                if previousWasQuote {
                    inString = false
                    previousWasQuote = false
                }

                if ch == dollarChar && !inString {
                    // Try to parse a number after $
                    var numEnd = i + 1
                    while numEnd < length {
                        let digit = nsSQL.character(at: numEnd)
                        if digit >= UInt16(UnicodeScalar("0").value) && digit <= UInt16(UnicodeScalar("9").value) {
                            numEnd += 1
                        } else {
                            break
                        }
                    }

                    if numEnd > i + 1,
                       let paramNumber = Int(nsSQL.substring(with: NSRange(location: i + 1, length: numEnd - i - 1))),
                       paramNumber >= 1 && paramNumber <= parameters.count {
                        // Flush accumulated characters before the placeholder
                        if rangeStart < i {
                            result += nsSQL.substring(with: NSRange(location: rangeStart, length: i - rangeStart))
                        }
                        result += formatValue(parameters[paramNumber - 1])
                        i = numEnd
                        rangeStart = i
                    } else {
                        i += 1
                    }
                } else {
                    i += 1
                }
            }
        }

        // Flush remaining characters
        if rangeStart < length {
            result += nsSQL.substring(with: NSRange(location: rangeStart, length: length - rangeStart))
        }

        return result
    }

    /// Formats a parameter value as a SQL literal string.
    private static func formatValue(_ value: Any?) -> String {
        guard let value else {
            return "NULL"
        }

        switch value {
        case let boolVal as Bool:
            return boolVal ? "TRUE" : "FALSE"
        case let intVal as Int:
            return String(intVal)
        case let int8Val as Int8:
            return String(int8Val)
        case let int16Val as Int16:
            return String(int16Val)
        case let int32Val as Int32:
            return String(int32Val)
        case let int64Val as Int64:
            return String(int64Val)
        case let uintVal as UInt:
            return String(uintVal)
        case let uint8Val as UInt8:
            return String(uint8Val)
        case let uint16Val as UInt16:
            return String(uint16Val)
        case let uint32Val as UInt32:
            return String(uint32Val)
        case let uint64Val as UInt64:
            return String(uint64Val)
        case let floatVal as Float:
            return String(floatVal)
        case let doubleVal as Double:
            return String(doubleVal)
        case let stringVal as String:
            return "'\(escapeString(stringVal))'"
        default:
            return "'\(escapeString(String(describing: value)))'"
        }
    }

    /// Escapes single quotes by doubling them for SQL string literals.
    private static func escapeString(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
