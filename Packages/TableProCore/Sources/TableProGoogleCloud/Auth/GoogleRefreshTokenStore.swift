import Foundation

public protocol GoogleRefreshTokenStore: Sendable {
    func refreshToken(for clientId: String) -> String?
    func save(_ refreshToken: String, for clientId: String)
    func removeRefreshToken(for clientId: String)
}

public final class GoogleInMemoryRefreshTokenStore: GoogleRefreshTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String]

    public init(_ initial: [String: String] = [:]) {
        tokens = initial
    }

    public func refreshToken(for clientId: String) -> String? {
        lock.withLock { tokens[clientId] }
    }

    public func save(_ refreshToken: String, for clientId: String) {
        lock.withLock { tokens[clientId] = refreshToken }
    }

    public func removeRefreshToken(for clientId: String) {
        lock.withLock { tokens[clientId] = nil }
    }
}
