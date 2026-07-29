import Foundation

public struct MCPUpstreamCredentials: Sendable, Equatable {
    public let endpoint: URL
    public let bearerToken: String
    public let tlsCertFingerprint: String?

    public init(endpoint: URL, bearerToken: String, tlsCertFingerprint: String? = nil) {
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.tlsCertFingerprint = tlsCertFingerprint
    }
}

public protocol MCPUpstreamCredentialsProviding: Sendable {
    func currentCredentials() async -> MCPUpstreamCredentials
    func refreshCredentials() async throws -> MCPUpstreamCredentials
}

public actor MCPCachedUpstreamCredentialsProvider: MCPUpstreamCredentialsProviding {
    private var cached: MCPUpstreamCredentials
    private let reacquire: @Sendable () async throws -> MCPUpstreamCredentials

    public init(
        initial: MCPUpstreamCredentials,
        reacquire: @escaping @Sendable () async throws -> MCPUpstreamCredentials
    ) {
        self.cached = initial
        self.reacquire = reacquire
    }

    public func currentCredentials() async -> MCPUpstreamCredentials {
        cached
    }

    public func refreshCredentials() async throws -> MCPUpstreamCredentials {
        let refreshed = try await reacquire()
        cached = refreshed
        return refreshed
    }
}
