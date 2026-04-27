//
//  SQLParameterExtractor.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum SQLParameterExtractor {
    static func extractParameters(from sql: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        scan(sql: sql) { name, _ in
            if !seen.contains(name) {
                seen.insert(name)
                result.append(name)
            }
        }
        return result
    }

    static func convertToNativeStyle(
        sql: String,
        parameters: [QueryParameter],
        style: ParameterStyle
    ) -> (sql: String, values: [Any?]) {
        let nsSQL = sql as NSString
        let length = nsSQL.length
        guard length > 0 else { return (sql: sql, values: []) }

        let paramLookup = Dictionary(parameters.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var resultSQL = ""
        var values: [Any?] = []
        var dollarIndex = 1
        var lastCopied = 0

        scan(sql: sql) { name, range in
            if lastCopied < range.location {
                resultSQL += nsSQL.substring(with: NSRange(location: lastCopied, length: range.location - lastCopied))
            }

            if let param = paramLookup[name] {
                values.append(param.isNull ? nil : param.value)
            } else {
                values.append(nil)
            }

            switch style {
            case .questionMark:
                resultSQL += "?"
            case .dollar:
                resultSQL += "$\(dollarIndex)"
                dollarIndex += 1
            }

            lastCopied = range.location + range.length
        }

        if lastCopied < length {
            resultSQL += nsSQL.substring(with: NSRange(location: lastCopied, length: length - lastCopied))
        }

        return (sql: resultSQL, values: values)
    }

    // MARK: - Private

    private static let singleQuote = UInt16(UnicodeScalar("'").value)
    private static let doubleQuote = UInt16(UnicodeScalar("\"").value)
    private static let backtick = UInt16(UnicodeScalar("`").value)
    private static let colonChar = UInt16(UnicodeScalar(":").value)
    private static let dash = UInt16(UnicodeScalar("-").value)
    private static let slash = UInt16(UnicodeScalar("/").value)
    private static let star = UInt16(UnicodeScalar("*").value)
    private static let newline = UInt16(UnicodeScalar("\n").value)
    private static let backslash = UInt16(UnicodeScalar("\\").value)
    private static let underscore = UInt16(UnicodeScalar("_").value)
    private static let dollarChar = UInt16(UnicodeScalar("$").value)

    private static func isIdentifierStart(_ ch: UInt16) -> Bool {
        (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) || ch == underscore
    }

    private static func isIdentifierChar(_ ch: UInt16) -> Bool {
        isIdentifierStart(ch) || (ch >= 0x30 && ch <= 0x39)
    }

    private static func scan(
        sql: String,
        onParameter: (_ name: String, _ range: NSRange) -> Void
    ) {
        let nsSQL = sql as NSString
        let length = nsSQL.length
        guard length > 0 else { return }

        var inString = false
        var stringCharVal: UInt16 = 0
        var inLineComment = false
        var inBlockComment = false
        var i = 0

        while i < length {
            let ch = nsSQL.character(at: i)

            if inLineComment {
                if ch == newline { inLineComment = false }
                i += 1
                continue
            }

            if inBlockComment {
                if ch == star && i + 1 < length && nsSQL.character(at: i + 1) == slash {
                    inBlockComment = false
                    i += 2
                    continue
                }
                i += 1
                continue
            }

            if !inString && ch == dash && i + 1 < length && nsSQL.character(at: i + 1) == dash {
                inLineComment = true
                i += 2
                continue
            }

            if !inString && ch == slash && i + 1 < length && nsSQL.character(at: i + 1) == star {
                inBlockComment = true
                i += 2
                continue
            }

            if inString && ch == backslash && i + 1 < length {
                i += 2
                continue
            }

            if ch == singleQuote || ch == doubleQuote || ch == backtick {
                if !inString {
                    inString = true
                    stringCharVal = ch
                } else if ch == stringCharVal {
                    if i + 1 < length && nsSQL.character(at: i + 1) == stringCharVal {
                        i += 1
                    } else {
                        inString = false
                    }
                }
                i += 1
                continue
            }

            if !inString && ch == dollarChar {
                let tagStart = i + 1
                if tagStart < length && nsSQL.character(at: tagStart) == dollarChar {
                    var j = tagStart + 1
                    while j < length - 1 {
                        if nsSQL.character(at: j) == dollarChar && nsSQL.character(at: j + 1) == dollarChar {
                            i = j + 2
                            break
                        }
                        j += 1
                    }
                    if i < tagStart + 1 { i = length }
                    continue
                }
                var tagEnd = tagStart
                while tagEnd < length && isIdentifierChar(nsSQL.character(at: tagEnd)) {
                    tagEnd += 1
                }
                if tagEnd > tagStart && tagEnd < length && nsSQL.character(at: tagEnd) == dollarChar {
                    let tagLen = tagEnd - i + 1
                    let openTag = nsSQL.substring(with: NSRange(location: i, length: tagLen))
                    var j = tagEnd + 1
                    var found = false
                    while j <= length - tagLen {
                        if nsSQL.character(at: j) == dollarChar {
                            let candidate = nsSQL.substring(with: NSRange(location: j, length: tagLen))
                            if candidate == openTag {
                                i = j + tagLen
                                found = true
                                break
                            }
                        }
                        j += 1
                    }
                    if !found { i = length }
                    continue
                }
            }

            if !inString && ch == colonChar {
                if i + 1 < length && nsSQL.character(at: i + 1) == colonChar {
                    i += 2
                    while i < length && isIdentifierChar(nsSQL.character(at: i)) {
                        i += 1
                    }
                    continue
                }

                if i + 1 < length && isIdentifierStart(nsSQL.character(at: i + 1)) {
                    let nameStart = i + 1
                    var nameEnd = nameStart
                    while nameEnd < length && isIdentifierChar(nsSQL.character(at: nameEnd)) {
                        nameEnd += 1
                    }
                    let paramRange = NSRange(location: i, length: nameEnd - i)
                    let name = nsSQL.substring(with: NSRange(location: nameStart, length: nameEnd - nameStart))
                    onParameter(name, paramRange)
                    i = nameEnd
                    continue
                }
            }

            i += 1
        }
    }
}
