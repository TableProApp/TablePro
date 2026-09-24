import Foundation

public enum JSONTableError: Error, Equatable, Sendable {
    case emptyDocument
    case unsupportedEncoding
    case singleObject(byteOffset: Int)
    case scalarDocument(byteOffset: Int)
    case rowIsNotAnObject(row: Int, byteOffset: Int)
    case truncated(row: Int, byteOffset: Int)
    case unexpectedByte(row: Int, byteOffset: Int)
    case mismatchedBracket(row: Int, byteOffset: Int)
    case trailingContent(row: Int, byteOffset: Int)
    case invalidString(row: Int, byteOffset: Int)
    case invalidEscape(row: Int, byteOffset: Int)
    case invalidNumber(row: Int, byteOffset: Int)
    case invalidLiteral(row: Int, byteOffset: Int)

    public var row: Int? {
        switch self {
        case .emptyDocument, .unsupportedEncoding, .singleObject, .scalarDocument:
            return nil
        case .rowIsNotAnObject(let row, _), .truncated(let row, _), .unexpectedByte(let row, _),
             .mismatchedBracket(let row, _), .trailingContent(let row, _), .invalidString(let row, _),
             .invalidEscape(let row, _), .invalidNumber(let row, _), .invalidLiteral(let row, _):
            return row
        }
    }

    public var byteOffset: Int {
        switch self {
        case .emptyDocument, .unsupportedEncoding:
            return 0
        case .singleObject(let offset), .scalarDocument(let offset):
            return offset
        case .rowIsNotAnObject(_, let offset), .truncated(_, let offset), .unexpectedByte(_, let offset),
             .mismatchedBracket(_, let offset), .trailingContent(_, let offset), .invalidString(_, let offset),
             .invalidEscape(_, let offset), .invalidNumber(_, let offset), .invalidLiteral(_, let offset):
            return offset
        }
    }
}
