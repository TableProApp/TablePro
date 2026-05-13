import Foundation

public enum HttpMethod: Sendable, Equatable {
    case get
    case post
    case delete
    case options
    case put
    case patch
    case head
    case other(String)

    public var rawValue: String {
        switch self {
        case .get: return "GET"
        case .post: return "POST"
        case .delete: return "DELETE"
        case .options: return "OPTIONS"
        case .put: return "PUT"
        case .patch: return "PATCH"
        case .head: return "HEAD"
        case .other(let value): return value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "GET": self = .get
        case "POST": self = .post
        case "DELETE": self = .delete
        case "OPTIONS": self = .options
        case "PUT": self = .put
        case "PATCH": self = .patch
        case "HEAD": self = .head
        default: self = .other(rawValue)
        }
    }
}

public struct HttpHeaders: Sendable, Equatable {
    private let storage: [(String, String)]

    public init(_ pairs: [(String, String)] = []) {
        storage = pairs
    }

    public var all: [(String, String)] {
        storage
    }

    public func value(for name: String) -> String? {
        let lowered = name.lowercased()
        for (key, value) in storage where key.lowercased() == lowered {
            return value
        }
        return nil
    }

    public func values(for name: String) -> [String] {
        let lowered = name.lowercased()
        return storage.compactMap { key, value in
            key.lowercased() == lowered ? value : nil
        }
    }

    public func contains(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return storage.contains { key, _ in key.lowercased() == lowered }
    }

    public static func == (lhs: HttpHeaders, rhs: HttpHeaders) -> Bool {
        guard lhs.storage.count == rhs.storage.count else { return false }
        for index in lhs.storage.indices {
            let leftPair = lhs.storage[index]
            let rightPair = rhs.storage[index]
            if leftPair.0 != rightPair.0 || leftPair.1 != rightPair.1 {
                return false
            }
        }
        return true
    }
}

public struct HttpRequestHead: Sendable, Equatable {
    public let method: HttpMethod
    public let path: String
    public let httpVersion: String
    public let headers: HttpHeaders

    public init(method: HttpMethod, path: String, httpVersion: String, headers: HttpHeaders) {
        self.method = method
        self.path = path
        self.httpVersion = httpVersion
        self.headers = headers
    }
}
