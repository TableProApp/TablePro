//
//  AWSIAMTokenSigner.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Signs the RDS or ElastiCache token an AWS IAM connection signs in with. It keeps its own copy
/// of the connection's settings, so a driver can ask for a new token without the main actor.
struct AWSIAMTokenSigner: Sendable {
    enum Target: Sendable, Equatable {
        case elastiCache(host: String, tlsDisabled: Bool)
        case rds(
            configuredHost: String,
            configuredPort: Int,
            preTunnelHost: String?,
            preTunnelPort: Int?,
            defaultPort: Int
        )
    }

    let source: String
    /// AWS checks the username inside the token against the one the connection signs in as.
    let username: String
    let fields: [String: String]
    let target: Target

    func token(deadline: ConnectionDeadline?) async throws -> String {
        let credentials = try await resolveCredentials(deadline: deadline)
        switch target {
        case .elastiCache(let host, let tlsDisabled):
            guard let region = fields["awsRegion"].flatMap({ $0.isEmpty ? nil : $0 }) else {
                throw AWSAuthError.regionUnknown(host: host)
            }
            guard !tlsDisabled else {
                throw AWSAuthError.missingConfiguration(
                    String(localized: "ElastiCache IAM authentication requires TLS. Enable SSL in the connection's SSL settings.")
                )
            }
            guard let replicationGroupId = fields["awsReplicationGroupId"].flatMap({ $0.isEmpty ? nil : $0 }) else {
                throw AWSAuthError.missingConfiguration(
                    String(localized: "Enter the ElastiCache cache name (replication group ID) to use IAM authentication.")
                )
            }
            return ElastiCacheAuthTokenGenerator.generateToken(
                replicationGroupId: replicationGroupId,
                region: region,
                userId: username,
                credentials: credentials
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
            let explicitRegion = fields["awsRegion"].flatMap { $0.isEmpty ? nil : $0 }
            guard let region = explicitRegion ?? RDSEndpoint.region(forHost: endpoint.host) else {
                throw AWSAuthError.regionUnknown(host: endpoint.host)
            }
            return RDSAuthTokenGenerator.generateToken(
                host: endpoint.host,
                port: endpoint.port,
                region: region,
                username: username,
                credentials: credentials
            )
        }
    }

    private func resolveCredentials(deadline: ConnectionDeadline?) async throws -> AWSCredentials {
        guard let deadline else {
            return try await AWSCredentialResolver.resolve(source: source, fields: fields)
        }
        let timeout = ConnectionCredentialResolver.credentialRequestTimeout(for: deadline)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await AWSCredentialResolver.resolve(source: source, fields: fields, session: session)
    }
}

extension AWSIAMTokenSigner {
    init(connection: DatabaseConnection, source: String, username: String, fields: [String: String]) {
        self.source = source
        self.username = username
        self.fields = fields
        if connection.type == .redis {
            target = .elastiCache(host: connection.host, tlsDisabled: connection.sslConfig.mode == .disabled)
        } else {
            target = .rds(
                configuredHost: connection.host,
                configuredPort: connection.port,
                preTunnelHost: connection.preTunnelHost,
                preTunnelPort: connection.preTunnelPort,
                defaultPort: PluginMetadataRegistry.shared.snapshot(for: connection.type)?.defaultPort ?? connection.port
            )
        }
    }
}
