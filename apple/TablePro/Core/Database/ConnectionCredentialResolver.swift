//
//  ConnectionCredentialResolver.swift
//  TablePro
//

import Foundation
import TableProGoogleCloud
import TableProPluginKit
import TableProUtilities

struct PgpassLookup: Hashable {
    let host: String
    let port: Int
    let database: String
    let username: String
}

// A connection signs in with one of: an IAM token minted per sign-in, a prompted override, a `PasswordSource` (a
// Vault database role answers for the username too), `~/.pgpass`, or the Keychain.
@MainActor
enum ConnectionCredentialResolver {
    static func resolvePassword(
        for connection: DatabaseConnection,
        fields: [String: String],
        override: String? = nil,
        deadline: ConnectionDeadline? = nil
    ) async throws -> String {
        try await resolveSignIn(for: connection, fields: fields, override: override, deadline: deadline).password
    }

    // A nil username keeps the connection's own; Redshift IAM and a Vault database role hand back another.
    // A sign-in that carries a lease belongs to whoever uses it, which releases it when done.
    static func resolveSignIn(
        for connection: DatabaseConnection,
        fields: [String: String],
        override: String? = nil,
        deadline: ConnectionDeadline? = nil
    ) async throws -> ResolvedSignIn {
        if let minter = iamPasswordMinter(for: connection, fields: fields) {
            return try await minter.mint(deadline: deadline)
        }
        return try await resolveStoredSignIn(for: connection, override: override)
    }

    // A lease is a database user Vault creates, so a caller that only wants to know whether a password exists asks this.
    static func signsInWithLease(_ connection: DatabaseConnection) -> Bool {
        effectivePasswordSource(for: connection)?.vaultDatabaseRole != nil
    }

    private static func effectivePasswordSource(for connection: DatabaseConnection) -> PasswordSource? {
        if case .profile(let profileId) = connection.credentialMode,
           let profile = CredentialProfileStorage.shared.profile(for: profileId) {
            guard case .source(let source) = profile.passwordMode else { return nil }
            return source
        }
        return connection.passwordSource
    }

    private static func resolveStoredSignIn(for connection: DatabaseConnection, override: String?) async throws -> ResolvedSignIn {
        if let override { return ResolvedSignIn(username: nil, password: override) }
        if case .profile(let profileId) = connection.credentialMode,
           let profile = CredentialProfileStorage.shared.profile(for: profileId) {
            return try await resolveProfileSignIn(profile, for: connection)
        }
        if let passwordSource = connection.passwordSource {
            guard ConnectionStorage.shared.storeIsTrusted else {
                throw PasswordSourceResolver.ResolutionError.storeNotTrusted
            }
            return try await resolveSource(passwordSource, for: connection)
        }
        if connection.usePgpass {
            return ResolvedSignIn(username: nil, password: pgpassPassword(for: connection, username: resolveUsername(for: connection)))
        }
        return ResolvedSignIn(username: nil, password: ConnectionStorage.shared.loadPassword(for: connection.id) ?? "")
    }

    private static func resolveSource(_ source: PasswordSource, for connection: DatabaseConnection) async throws -> ResolvedSignIn {
        if case .vaultDatabaseRole(let role) = source {
            return try await VaultDatabaseCredentials.shared.signIn(role, interactive: false)
        }
        let password = try await PasswordSourceResolver.resolve(source, for: ConnectionScriptContext(connection: connection))
        return ResolvedSignIn(username: nil, password: password)
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

    private static func resolveProfileSignIn(
        _ profile: CredentialProfile,
        for connection: DatabaseConnection
    ) async throws -> ResolvedSignIn {
        switch profile.passwordMode {
        case .stored:
            return ResolvedSignIn(username: nil, password: CredentialProfileStorage.shared.loadPassword(for: profile.id) ?? "")
        case .prompt:
            // The prompt's answer arrives as `override`; reaching here means it was declined or the connect is unattended.
            return ResolvedSignIn(username: nil, password: "")
        case .pgpass:
            return ResolvedSignIn(username: nil, password: pgpassPassword(for: connection, username: profile.username))
        case .source(let source):
            // A source can name a shell command, or a Vault address to send a token to.
            guard CredentialProfileStorage.shared.storeIsTrusted else {
                throw PasswordSourceResolver.ResolutionError.profileStoreNotTrusted
            }
            return try await resolveSource(source, for: connection)
        }
    }

    private static func pgpassPassword(for connection: DatabaseConnection, username: String) -> String {
        let lookup = pgpassLookup(for: connection, username: username)
        return PgpassReader.resolve(
            host: lookup.host,
            port: lookup.port,
            database: lookup.database,
            username: lookup.username
        ) ?? ""
    }

    // What libpq looks up in ~/.pgpass: a socket by its directory, a blank user as the login name.
    nonisolated static func pgpassLookup(for connection: DatabaseConnection, username: String) -> PgpassLookup {
        var host = connection.preTunnelHost ?? connection.host
        var port = connection.preTunnelPort ?? connection.port
        if connection.type.localSocketIsDirectory, let socket = connection.localSocketEndpoint {
            host = socket.path
            port = socket.port
        }
        return PgpassLookup(
            host: PostgreSQLLocalSocket.pgpassHost(forHost: host),
            port: port,
            database: connection.database,
            username: PgpassReader.effectiveUsername(username)
        )
    }

    // The AWS token is signed for the resolved username: `connection.username` can lag behind its profile.
    static func iamPasswordMinter(
        for connection: DatabaseConnection,
        fields: [String: String]
    ) -> IAMPasswordMinter? {
        switch connection.iamSignIn {
        case .aws(let source) where connection.type == .redshift:
            return .redshift(RedshiftIAMSignIn(connection: connection, source: source, fields: fields))
        case .aws(let source):
            guard !connection.resolvesAWSIAMInDriver else { return nil }
            return .aws(AWSIAMTokenSigner(
                connection: connection,
                source: source,
                username: resolveUsername(for: connection),
                fields: fields
            ))
        case .googleCloud(.applicationDefault):
            return .googleCloud(CloudSQLIAMLogin(connectionId: connection.id, source: .applicationDefault))
        case .googleCloud(.serviceAccount):
            let key = fields[GoogleCloudSQLAuthFields.serviceAccountKeyFieldId] ?? ""
            return .googleCloud(CloudSQLIAMLogin(connectionId: connection.id, source: .serviceAccountKey(key)))
        case nil:
            return nil
        }
    }

    nonisolated static func credentialRequestTimeout(
        for deadline: ConnectionDeadline,
        at now: ContinuousClock.Instant = .now
    ) -> TimeInterval {
        TimeInterval(max(1, deadline.remainingMilliseconds(at: now))) / 1_000
    }
}

struct ResolvedSignIn: Equatable, Sendable {
    let username: String?
    let password: String
    let lease: VaultLease?

    init(username: String?, password: String, lease: VaultLease? = nil) {
        self.username = username
        self.password = password
        self.lease = lease
    }
}
