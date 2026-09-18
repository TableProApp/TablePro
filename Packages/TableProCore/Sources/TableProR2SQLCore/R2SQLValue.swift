import Foundation

public enum R2SQLValue: Sendable, Equatable {
    case null
    case text(String)
    case bytes([UInt8])
}
