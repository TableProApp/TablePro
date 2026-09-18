import Foundation

public protocol GoogleAccessTokenProviding: Sendable {
    func accessToken() async throws -> String
    func invalidateCachedToken() async
}
