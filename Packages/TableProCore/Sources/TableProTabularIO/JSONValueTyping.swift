import Foundation

public enum JSONValueTypingError: Error, Equatable, Sendable {
    case invalidJSON(kind: TabularCellKind, byteOffset: Int)
}

public enum JSONValueTyping {
    public static func literal(for text: String, originalKind: TabularCellKind) throws -> String {
        switch originalKind {
        case .number:
            return isNumberLexeme(text) ? text : JSONText.stringLiteral(text)
        case .boolean:
            return text == "true" || text == "false" ? text : JSONText.stringLiteral(text)
        case .null:
            return text == "null" ? text : JSONText.stringLiteral(text)
        case .object, .array:
            return try containerLiteral(text, kind: originalKind)
        case .text, .missing, .error, .date:
            return JSONText.stringLiteral(text)
        }
    }

    public static func isNumberLexeme(_ text: String) -> Bool {
        var copy = text
        return copy.withUTF8 { bytes -> Bool in
            guard let base = bytes.baseAddress, let first = bytes.first else { return false }
            guard first == JSONByte.minus || JSONByte.isDigit(first) else { return false }
            let cursor = JSONCursor(base: base, count: bytes.count, row: 0)
            return (try? cursor.number(at: 0)) == bytes.count
        }
    }

    private static func containerLiteral(_ text: String, kind: TabularCellKind) throws -> String {
        var copy = text
        do {
            _ = try copy.withUTF8 { try JSONRowParser.validateValue(in: $0) }
        } catch let error as JSONTableError {
            throw JSONValueTypingError.invalidJSON(kind: kind, byteOffset: error.byteOffset)
        }
        return JSONText.compact(text)
    }
}
