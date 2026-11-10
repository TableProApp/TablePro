import Foundation

public struct MCPUpstreamCredentials: Sendable, Equatable {
    public let socketPath: String
    public let serverPID: Int32
    public let bearerToken: String

    public init(socketPath: String, serverPID: Int32, bearerToken: String) {
        self.socketPath = socketPath
        self.serverPID = serverPID
        self.bearerToken = bearerToken
    }
}

public protocol MCPUpstreamCredentialsProviding: Sendable {
    func currentCredentials() async -> MCPUpstreamCredentials
    func refreshCredentials() async throws -> MCPUpstreamCredentials
}

public actor MCPCachedUpstreamCredentialsProvider: MCPUpstreamCredentialsProviding {
    private var cached: MCPUpstreamCredentials
    private var refreshing: Task<MCPUpstreamCredentials, Error>?
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

    // Requests that fail together share one re-acquire, so the app is launched and verified once.
    public func refreshCredentials() async throws -> MCPUpstreamCredentials {
        if let refreshing {
            return try await refreshing.value
        }
        let reacquire = reacquire
        let task = Task { try await reacquire() }
        refreshing = task
        defer { refreshing = nil }
        let refreshed = try await task.value
        cached = refreshed
        return refreshed
    }
}
