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
        if case .profile(let profileId) = connection.credentialMode,
           let profile = CredentialProfileStorage.shared.profile(for: profileId) {
            return try await resolveProfilePassword(profile, for: connection)
        }
        if let passwordSource = connection.passwordSource {
            guard await ConnectionStorage.shared.storeIsTrusted else {
                throw PasswordSourceResolver.ResolutionError.storeNotTrusted
            }
            return try await PasswordSourceResolver.resolve(passwordSource)
        }
        if connection.usePgpass {
            return pgpassPassword(for: connection, username: resolveUsername(for: connection))
        }
        return ConnectionStorage.shared.loadPassword(for: connection.id) ?? ""
    }

    /// The username a connect signs in as.
    ///
    /// `CredentialProfileStorage.writeUsernameThrough` keeps `connection.username` current for
    /// every other reader, which is most of them. This covers the window before one of those writes
    /// has run: a profile edited on another Mac and synced down, or a connection whose store could
    /// not be written.
    static func resolveUsername(for connection: DatabaseConnection) -> String {
        guard case .profile(let profileId) = connection.credentialMode,
              let profile = CredentialProfileStorage.shared.profile(for: profileId)
        else { return connection.username }
        return profile.username
    }

    /// Which record a prompted password is remembered against. A profile answers for every
    /// connection linked to it, so one profile in "ask every time" mode asks once per launch
    /// rather than once per connection.
    static func promptCacheKey(for connection: DatabaseConnection) -> UUID {
        connection.credentialMode.profileId ?? connection.id
    }

    /// Whether a connect has to ask for the password, which a linked profile answers for.
    static func promptsForPassword(_ connection: DatabaseConnection) -> Bool {
        guard case .profile(let profileId) = connection.credentialMode,
              let profile = CredentialProfileStorage.shared.profile(for: profileId)
        else { return connection.promptForPassword }
        if case .prompt = profile.passwordMode { return true }
        return false
    }

    private static func resolveProfilePassword(
        _ profile: CredentialProfile,
        for connection: DatabaseConnection
    ) async throws -> String {
        switch profile.passwordMode {
        case .stored:
            return CredentialProfileStorage.shared.loadPassword(for: profile.id) ?? ""
        case .prompt:
            /// The prompt runs before the driver is built and arrives back as `override`, so
            /// reaching here means it was declined or the connect is a background one.
            return ""
        case .pgpass:
            return pgpassPassword(for: connection, username: profile.username)
        case .source(let source):
            /// The profiles file carries its own tag for exactly this: a source can name a shell
            /// command, so the file has to be the one TablePro last wrote before one runs.
            guard CredentialProfileStorage.shared.storeIsTrusted else {
                throw PasswordSourceResolver.ResolutionError.storeNotTrusted
            }
            return try await PasswordSourceResolver.resolve(source)
        }
    }

    private static func pgpassPassword(for connection: DatabaseConnection, username: String) -> String {
        let host = connection.preTunnelHost ?? connection.host
        let port = connection.preTunnelPort ?? connection.port
        return PgpassReader.resolve(
            host: host.isEmpty ? "localhost" : host,
            port: port,
            database: connection.database,
            username: username
        ) ?? ""
    }

    /// AWS validates the username inside the token against the one used to connect, so this signs
    /// with the resolved username rather than `connection.username`, which can lag behind the
    /// profile until a write-through lands.
    static func resolveIAMPassword(
        for connection: DatabaseConnection,
        fields: [String: String]
    ) async throws -> String {
        let username = resolveUsername(for: connection)
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
                userId: username,
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
            username: username,
            credentials: credentials
        )
    }
}
