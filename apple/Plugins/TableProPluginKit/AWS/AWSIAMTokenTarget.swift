import Foundation

public enum AWSIAMTokenTarget: Sendable, Equatable {
    case elastiCache(host: String, tlsDisabled: Bool)
    case rds(
        configuredHost: String,
        configuredPort: Int,
        preTunnelHost: String?,
        preTunnelPort: Int?,
        defaultPort: Int
    )

    public func token(
        username: String,
        fields: [String: String],
        credentials: AWSCredentials,
        now: Date = Date()
    ) throws -> String {
        switch self {
        case .elastiCache(let host, let tlsDisabled):
            guard let region = Self.nonEmpty(fields["awsRegion"]) else {
                throw AWSAuthError.regionUnknown(host: host)
            }
            guard !tlsDisabled else {
                throw AWSAuthError.missingConfiguration(
                    String(localized: "ElastiCache IAM authentication requires TLS. Enable SSL in the connection's SSL settings.")
                )
            }
            guard let replicationGroupId = Self.nonEmpty(fields["awsReplicationGroupId"]) else {
                throw AWSAuthError.missingConfiguration(
                    String(localized: "Enter the ElastiCache cache name (replication group ID) to use IAM authentication.")
                )
            }
            return ElastiCacheAuthTokenGenerator.generateToken(
                replicationGroupId: replicationGroupId,
                region: region,
                userId: username,
                credentials: credentials,
                now: now
            )
        case .rds(let configuredHost, let configuredPort, let preTunnelHost, let preTunnelPort, let defaultPort):
            let endpoint = try RDSSigningEndpointResolver.resolve(
                configuredHost: configuredHost,
                configuredPort: configuredPort,
                preTunnelHost: preTunnelHost,
                preTunnelPort: preTunnelPort,
                override: fields["awsRDSEndpoint"],
                defaultPort: defaultPort
            )
            guard let region = Self.nonEmpty(fields["awsRegion"]) ?? RDSEndpoint.region(forHost: endpoint.host) else {
                throw AWSAuthError.regionUnknown(host: endpoint.host)
            }
            return RDSAuthTokenGenerator.generateToken(
                host: endpoint.host,
                port: endpoint.port,
                region: region,
                username: username,
                credentials: credentials,
                now: now
            )
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
