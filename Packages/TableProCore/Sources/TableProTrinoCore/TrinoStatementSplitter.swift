import Foundation

public enum TrinoStatementSplitter {
    private static let singleQuote = UInt16(UnicodeScalar("'").value)
    private static let doubleQuote = UInt16(UnicodeScalar("\"").value)
    private static let semicolon = UInt16(UnicodeScalar(";").value)
    private static let dash = UInt16(UnicodeScalar("-").value)
    private static let slash = UInt16(UnicodeScalar("/").value)
    private static let star = UInt16(UnicodeScalar("*").value)
    private static let newline = UInt16(UnicodeScalar("\n").value)
    private static let space = UInt16(UnicodeScalar(" ").value)
    private static let tab = UInt16(UnicodeScalar("\t").value)
    private static let carriageReturn = UInt16(UnicodeScalar("\r").value)

    public static func split(_ sql: String) -> [String] {
        let text = sql as NSString
        let length = text.length
        var statements: [String] = []
        var start = 0
        var index = 0
        var inSingle = false
        var inDouble = false
        var inLineComment = false
        var inBlockComment = false
        var hasContent = false

        while index < length {
            let char = text.character(at: index)

            if inLineComment {
                if char == newline { inLineComment = false }
                index += 1
                continue
            }
            if inBlockComment {
                if char == star, index + 1 < length, text.character(at: index + 1) == slash {
                    inBlockComment = false
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            if inSingle {
                hasContent = true
                if char == singleQuote {
                    if index + 1 < length, text.character(at: index + 1) == singleQuote {
                        index += 2
                        continue
                    }
                    inSingle = false
                }
                index += 1
                continue
            }
            if inDouble {
                hasContent = true
                if char == doubleQuote {
                    if index + 1 < length, text.character(at: index + 1) == doubleQuote {
                        index += 2
                        continue
                    }
                    inDouble = false
                }
                index += 1
                continue
            }

            if char == singleQuote {
                inSingle = true
                hasContent = true
            } else if char == doubleQuote {
                inDouble = true
                hasContent = true
            } else if char == dash, index + 1 < length, text.character(at: index + 1) == dash {
                inLineComment = true
                index += 2
                continue
            } else if char == slash, index + 1 < length, text.character(at: index + 1) == star {
                inBlockComment = true
                index += 2
                continue
            } else if char == semicolon {
                appendStatement(text, from: start, to: index, hasContent: hasContent, into: &statements)
                start = index + 1
                hasContent = false
            } else if !isWhitespace(char) {
                hasContent = true
            }
            index += 1
        }

        appendStatement(text, from: start, to: length, hasContent: hasContent, into: &statements)
        return statements
    }

    private static func isWhitespace(_ char: UInt16) -> Bool {
        char == space || char == tab || char == newline || char == carriageReturn
    }

    private static func appendStatement(
        _ text: NSString,
        from start: Int,
        to end: Int,
        hasContent: Bool,
        into statements: inout [String]
    ) {
        guard hasContent, end > start else { return }
        let candidate = text
            .substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty {
            statements.append(candidate)
        }
    }
}
