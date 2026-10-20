import Foundation
import TableProTabularIO

nonisolated enum JSONValidation {
    nonisolated struct Failure: Error, Equatable, Sendable {
        let byteOffset: Int
        let line: Int
        let column: Int
        let utf16Offset: Int
        let reason: String

        var message: String {
            String(format: String(localized: "Line %lld, column %lld: %@"), line, column, reason)
        }
    }

    private static let lineBreaks: Set<Unicode.Scalar> = ["\n", "\r", "\u{85}", "\u{2028}", "\u{2029}"]

    static func check(_ text: String) -> Result<TabularCellKind, Failure> {
        var source = text
        do {
            let kind = try source.withUTF8 { try JSONRowParser.validateValue(in: $0) }
            return .success(kind)
        } catch let error as JSONTableError {
            return .failure(failure(in: text, byteOffset: error.byteOffset, reason: reason(for: error)))
        } catch {
            return .failure(failure(in: text, byteOffset: 0, reason: String(localized: "Not valid JSON.")))
        }
    }

    private static func failure(in text: String, byteOffset: Int, reason: String) -> Failure {
        let scalars = text.unicodeScalars
        let utf8 = text.utf8
        var position = utf8.index(utf8.startIndex, offsetBy: min(max(byteOffset, 0), utf8.count))
        while position > utf8.startIndex, position.samePosition(in: scalars) == nil {
            position = utf8.index(before: position)
        }
        var line = 1
        var lineStart = scalars.startIndex
        var previous: Unicode.Scalar?
        var index = scalars.startIndex
        while index < position {
            let scalar = scalars[index]
            index = scalars.index(after: index)
            if lineBreaks.contains(scalar) {
                if !(scalar == "\n" && previous == "\r") { line += 1 }
                lineStart = index
            }
            previous = scalar
        }
        return Failure(
            byteOffset: byteOffset,
            line: line,
            column: text[lineStart..<position].count + 1,
            utf16Offset: text.utf16.distance(from: text.startIndex, to: position),
            reason: reason
        )
    }

    private static func reason(for error: JSONTableError) -> String {
        switch error {
        case .truncated:
            String(localized: "The JSON ends before it is complete.")
        case .unexpectedByte:
            String(localized: "Unexpected character.")
        case .mismatchedBracket:
            String(localized: "This bracket does not close the one that is open.")
        case .trailingContent:
            String(localized: "Extra text after the JSON value.")
        case .invalidString:
            String(localized: "A string cannot hold a line break, tab or other control character.")
        case .invalidEscape:
            String(localized: "Invalid escape sequence.")
        case .invalidNumber:
            String(localized: "Invalid number.")
        case .invalidLiteral:
            String(localized: "Expected true, false or null.")
        default:
            String(localized: "Not valid JSON.")
        }
    }
}
