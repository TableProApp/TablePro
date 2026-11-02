import Foundation

public enum WireIOError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case truncated(needed: Int, available: Int)
    case lengthOutOfRange(String, limit: Int)
    case expansionExceeded(produced: Int, consumed: Int)

    public var description: String {
        switch self {
        case .truncated(let needed, let available):
            return "truncated: needed \(needed) bytes, \(available) left"
        case .lengthOutOfRange(let length, let limit):
            return "length \(length) is outside 0...\(limit)"
        case .expansionExceeded(let produced, let consumed):
            return "decompressed data passed its limit: \(produced) bytes from \(consumed)"
        }
    }

    public var errorDescription: String? { description }
}
