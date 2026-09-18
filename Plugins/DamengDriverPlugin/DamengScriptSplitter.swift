import Foundation

/// Splits a generated script into the statements DM8 will accept one at a time.
///
/// DM8 has no batch execute: a string holding more than one statement is rejected outright with
/// `-2004 不支持的语句类型` ("unsupported statement type"), so a driver handed one has to send the
/// parts in order. TablePro's own generated DDL is exactly that shape, because creating a table
/// with an index or a column comment takes several statements.
///
/// The scan is deliberately conservative. It tracks the literal, identifier and comment nesting
/// `DamengParameterBinder` tracks, so a semicolon inside any of them is not a boundary, and it
/// refuses to split at all once a PL/SQL block keyword appears. Pairing `BEGIN`, `CASE`, `IF` and
/// `LOOP` against `END`, `END IF`, `END LOOP` and `END CASE` is more structure than a driver needs
/// to guess at, and guessing wrong cuts a block in half and sends the server a fragment. Passing
/// such a script through whole is what happened before this splitter existed.
enum DamengScriptSplitter {
    private enum State: Equatable {
        case code
        case singleQuote
        case doubleQuote
        case alternativeQuote(UnicodeScalar)
        case lineComment
        case blockComment(Int)
    }

    /// Anything that opens or closes a PL/SQL block. One of these anywhere outside a literal
    /// means the script keeps its semicolons and is sent as it arrived.
    private static let blockKeywords: Set<String> = [
        "BEGIN", "CASE", "DECLARE", "END", "IF", "LOOP"
    ]

    /// Returns the statements in order. A script that holds one statement, or that contains a
    /// PL/SQL block, comes back as a single entry with its text unchanged.
    static func statements(in script: String, escaping: DamengTextEscaping = .unknown) -> [String] {
        var results: [String] = []
        var current = String.UnicodeScalarView()
        var state = State.code
        var word = String.UnicodeScalarView()
        let scalars = Array(script.unicodeScalars)
        var index = 0

        func flush() {
            let statement = String(String.UnicodeScalarView(current))
            if hasStatementContent(statement) {
                results.append(statement.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            current = String.UnicodeScalarView()
        }

        /// Returns false as soon as a block keyword lands, which abandons the split.
        func endWord() -> Bool {
            defer { word = String.UnicodeScalarView() }
            guard !word.isEmpty else { return true }
            return !blockKeywords.contains(String(String.UnicodeScalarView(word)).uppercased())
        }

        while index < scalars.count {
            let scalar = scalars[index]
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil

            switch state {
            case .code:
                if scalar == "-", next == "-" {
                    guard endWord() else { return [script] }
                    state = .lineComment
                } else if scalar == "/", next == "*" {
                    guard endWord() else { return [script] }
                    state = .blockComment(1)
                    current.append(scalar)
                    index += 1
                    current.append(scalars[index])
                    index += 1
                    continue
                } else if scalar == "'" {
                    guard endWord() else { return [script] }
                    state = .singleQuote
                } else if scalar == "\"" {
                    guard endWord() else { return [script] }
                    state = .doubleQuote
                } else if isAlternativeQuoteStart(scalars, at: index) {
                    guard endWord() else { return [script] }
                    state = .alternativeQuote(alternativeQuoteCloser(scalars[index + 2]))
                    current.append(contentsOf: scalars[index...index + 2])
                    index += 3
                    continue
                } else if scalar == ";" {
                    guard endWord() else { return [script] }
                    flush()
                    index += 1
                    continue
                } else if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                    word.append(scalar)
                } else {
                    guard endWord() else { return [script] }
                }
            case .singleQuote:
                if escaping == .backslashEscape, scalar == "\\", let next {
                    current.append(scalar)
                    index += 1
                    current.append(next)
                    index += 1
                    continue
                }
                if scalar == "'" {
                    if next == "'" {
                        current.append(scalar)
                        index += 1
                        current.append(scalars[index])
                        index += 1
                        continue
                    }
                    state = .code
                }
            case .doubleQuote:
                if scalar == "\"" {
                    if next == "\"" {
                        current.append(scalar)
                        index += 1
                        current.append(scalars[index])
                        index += 1
                        continue
                    }
                    state = .code
                }
            case .alternativeQuote(let closer):
                if scalar == closer, next == "'" {
                    current.append(scalar)
                    index += 1
                    current.append(scalars[index])
                    index += 1
                    state = .code
                    continue
                }
            case .lineComment:
                if scalar == "\n" || scalar == "\r" { state = .code }
            case .blockComment(let depth):
                if scalar == "/", next == "*" {
                    state = .blockComment(depth + 1)
                    current.append(scalar)
                    index += 1
                    current.append(scalars[index])
                    index += 1
                    continue
                } else if scalar == "*", next == "/" {
                    state = depth == 1 ? .code : .blockComment(depth - 1)
                    current.append(scalar)
                    index += 1
                    current.append(scalars[index])
                    index += 1
                    continue
                }
            }

            current.append(scalar)
            index += 1
        }

        guard endWord() else { return [script] }
        flush()
        return results
    }

    /// A segment holding only comments and whitespace is not a statement. Sending one to DM8
    /// fails the script after its real work has already run.
    private static func hasStatementContent(_ segment: String) -> Bool {
        var state = State.code
        let scalars = Array(segment.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            switch state {
            case .lineComment:
                if scalar == "\n" || scalar == "\r" { state = .code }
            case .blockComment(let depth):
                if scalar == "/", next == "*" {
                    state = .blockComment(depth + 1)
                    index += 2
                    continue
                }
                if scalar == "*", next == "/" {
                    state = depth == 1 ? .code : .blockComment(depth - 1)
                    index += 2
                    continue
                }
            default:
                if scalar == "-", next == "-" {
                    state = .lineComment
                    index += 2
                    continue
                }
                if scalar == "/", next == "*" {
                    state = .blockComment(1)
                    index += 2
                    continue
                }
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
            }
            index += 1
        }
        return false
    }

    private static func isAlternativeQuoteStart(_ scalars: [UnicodeScalar], at index: Int) -> Bool {
        guard index + 2 < scalars.count else { return false }
        return (scalars[index] == "Q" || scalars[index] == "q") && scalars[index + 1] == "'"
    }

    private static func alternativeQuoteCloser(_ opener: UnicodeScalar) -> UnicodeScalar {
        switch opener {
        case "[": return "]"
        case "(": return ")"
        case "{": return "}"
        case "<": return ">"
        default: return opener
        }
    }
}
