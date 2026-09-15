//
//  ConnectionCredentialResolver.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The one answer to "what password does this connection sign in with".
///
/// A connection can get its password from five places: an AWS IAM token minted per connect, an
/// explicit override from a prompt, a `PasswordSource` (a file, an environment variable, the stdout
/// of a shell command, 1Password, Vault, AWS Secrets Manager), `~/.pgpass`, or the Keychain. Only
/// the connect path knew all five. `NativeDumpService` read the Keychain directly, so a backup of a
/// connection whose password comes from 1Password or `~/.pgpass` ran with an empty password and
/// failed against a server the app itself was connected to.
@MainActor
enum ConnectionCredentialResolver {
    static func resolvePassword(
        for connection: DatabaseConnection,
        fields: [String: String],
        override: String? = nil
    ) async throws -> String {
        if connection.usesAWSIAM, !connection.resolvesAWSIAMInDriver {
            return try await resolveIAMPassword(for: connection, fields: fields)
        }
        if let override { return override }
        if let passwordSource = connection.passwordSource {
            guard await ConnectionStorage.shared.storeIsTrusted else {
                throw PasswordSourceResolver.ResolutionError.storeNotTrusted
            }
            return try await PasswordSourceResolver.resolve(passwordSource)
        }
        if connection.usePgpass {
            let pgpassHost = connection.preTunnelHost ?? connection.host
            let pgpassPort = connection.preTunnelPort ?? connection.port
            return PgpassReader.resolve(
                host: pgpassHost.isEmpty ? "localhost" : pgpassHost,
                port: pgpassPort,
                database: connection.database,
                username: connection.username
            ) ?? ""
        }
        return ConnectionStorage.shared.loadPassword(for: connection.id) ?? ""
    }

    static func resolveIAMPassword(
        for connection: DatabaseConnection,
        fields: [String: String]
    ) async throws -> String {
        let source = fields["awsAuth"] ?? "accessKey"
        let credentials = try await AWSCredentialResolver.resolve(source: source, fields: fields)

        if connection.type == .redis {
            guard let region = fields["awsRegion"].flatMap({ $0.isEmpty ? nil : $0 }) else {
                throw AWSAuthError.regionUnknown(host: connection.host)
            }
            guard connection.sslConfig.mode != .disabled else {
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
                userId: connection.username,
                credentials: credentials
            )
        }

        let endpoint = try RDSSigningEndpointResolver.resolve(
            configuredHost: connection.host,
            configuredPort: connection.port,
            preTunnelHost: connection.preTunnelHost,
            preTunnelPort: connection.preTunnelPort,
            override: fields["awsRDSEndpoint"],
            defaultPort: PluginMetadataRegistry.shared
                .snapshot(for: connection.type)?.defaultPort ?? connection.port
        )

        let explicitRegion = fields["awsRegion"].flatMap { $0.isEmpty ? nil : $0 }
        guard let region = explicitRegion ?? RDSEndpoint.region(forHost: endpoint.host) else {
            throw AWSAuthError.regionUnknown(host: endpoint.host)
        }
        return RDSAuthTokenGenerator.generateToken(
            host: endpoint.host,
            port: endpoint.port,
            region: region,
            username: connection.username,
            credentials: credentials
        )
    }
}
