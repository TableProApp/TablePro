import Foundation

public enum JsonRpcVersionError: Error, Equatable, Sendable {
    case unsupported(String)
}

public enum JsonRpcVersion {
    public static let current = "2.0"

    public static func validate(_ value: String) throws {
        guard value == current else {
            throw JsonRpcVersionError.unsupported(value)
        }
    }
}
