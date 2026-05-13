import Foundation
@preconcurrency import Security

public enum MCPBindAddress: Sendable, Equatable {
    case loopback
    case anyInterface
}

public enum TLSProtocolVersion: Sendable, Equatable {
    case tls12
    case tls13
}

public struct MCPTLSConfiguration: Sendable {
    public let identity: SecIdentity
    public let minimumProtocol: TLSProtocolVersion

    public init(identity: SecIdentity, minimumProtocol: TLSProtocolVersion = .tls12) {
        self.identity = identity
        self.minimumProtocol = minimumProtocol
    }
}

public struct MCPHttpServerLimits: Sendable, Equatable {
    public let maxRequestBodyBytes: Int
    public let maxHeaderBytes: Int
    public let connectionTimeout: Duration

    public init(
        maxRequestBodyBytes: Int,
        maxHeaderBytes: Int,
        connectionTimeout: Duration
    ) {
        self.maxRequestBodyBytes = maxRequestBodyBytes
        self.maxHeaderBytes = maxHeaderBytes
        self.connectionTimeout = connectionTimeout
    }

    public static let standard = MCPHttpServerLimits(
        maxRequestBodyBytes: 10 * 1_024 * 1_024,
        maxHeaderBytes: 16 * 1_024,
        connectionTimeout: .seconds(30)
    )
}

public struct MCPHttpServerConfiguration: Sendable {
    public let bindAddress: MCPBindAddress
    public let port: UInt16
    public let tls: MCPTLSConfiguration?
    public let limits: MCPHttpServerLimits

    private init(
        bindAddress: MCPBindAddress,
        port: UInt16,
        tls: MCPTLSConfiguration?,
        limits: MCPHttpServerLimits
    ) {
        self.bindAddress = bindAddress
        self.port = port
        self.tls = tls
        self.limits = limits
    }

    public static func loopback(
        port: UInt16,
        limits: MCPHttpServerLimits = .standard
    ) -> Self {
        Self(bindAddress: .loopback, port: port, tls: nil, limits: limits)
    }

    public static func loopback(
        port: UInt16,
        tls: MCPTLSConfiguration,
        limits: MCPHttpServerLimits = .standard
    ) -> Self {
        Self(bindAddress: .loopback, port: port, tls: tls, limits: limits)
    }

    public static func remote(
        port: UInt16,
        tls: MCPTLSConfiguration,
        limits: MCPHttpServerLimits = .standard
    ) -> Self {
        Self(bindAddress: .anyInterface, port: port, tls: tls, limits: limits)
    }

    internal static func unsafeMake(
        bindAddress: MCPBindAddress,
        port: UInt16,
        tls: MCPTLSConfiguration?,
        limits: MCPHttpServerLimits
    ) -> Self {
        Self(bindAddress: bindAddress, port: port, tls: tls, limits: limits)
    }
}
