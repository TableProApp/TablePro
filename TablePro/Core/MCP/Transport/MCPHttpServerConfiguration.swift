import Foundation

public struct MCPHttpServerLimits: Sendable, Equatable {
    public let maxRequestBodyBytes: Int
    public let maxHeaderBytes: Int
    public let connectionTimeout: Duration
    public let maxConcurrentConnections: Int

    public init(
        maxRequestBodyBytes: Int,
        maxHeaderBytes: Int,
        connectionTimeout: Duration,
        maxConcurrentConnections: Int = 64
    ) {
        self.maxRequestBodyBytes = maxRequestBodyBytes
        self.maxHeaderBytes = maxHeaderBytes
        self.connectionTimeout = connectionTimeout
        self.maxConcurrentConnections = maxConcurrentConnections
    }

    public static let standard = MCPHttpServerLimits(
        maxRequestBodyBytes: 10 * 1_024 * 1_024,
        maxHeaderBytes: 16 * 1_024,
        connectionTimeout: .seconds(30),
        maxConcurrentConnections: 64
    )

    public var parserLimits: HttpParserLimits {
        HttpParserLimits(maxHeaderBytes: maxHeaderBytes, maxBodyBytes: maxRequestBodyBytes)
    }
}

public struct MCPHttpServerConfiguration: Sendable, Equatable {
    public let port: UInt16
    public let limits: MCPHttpServerLimits

    public init(port: UInt16, limits: MCPHttpServerLimits = .standard) {
        self.port = port
        self.limits = limits
    }

    public static func loopback(
        port: UInt16,
        limits: MCPHttpServerLimits = .standard
    ) -> Self {
        Self(port: port, limits: limits)
    }
}
