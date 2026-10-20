import Foundation
import TableProDatabase
import TableProGoogleCloud
import TableProModels
import TableProPluginKit

// The token is never stored: replayed after it expires, it fails the next sign-in.
nonisolated struct IAMPasswordMint: Sendable {
    typealias RoleCredentialsFetch = @Sendable (
        _ accessToken: String,
        _ settings: AWSSSOProfileSettings,
        _ profileName: String
    ) async throws -> AWSCredentials
    typealias GoogleTokenFetch = @Sendable (GoogleServiceAccountKey) async throws -> String

    static let liveRoleCredentials: RoleCredentialsFetch = { accessToken, settings, profileName in
        let role = try await AWSSSO.fetchRoleCredentials(
            accessToken: accessToken,
            settings: settings,
            profileName: profileName,
            session: AWSHTTP.shared
        )
        return AWSCredentials(
            accessKeyId: role.accessKeyId,
            secretAccessKey: role.secretAccessKey,
            sessionToken: role.sessionToken,
            expiration: role.expiration
        )
    }

    static let liveGoogleToken: GoogleTokenFetch = { key in
        try await GoogleTokenProviders.serviceAccount(
            key,
            scopes: GoogleCloudSQLLogin.scopes,
            http: URLSessionGoogleHTTPClient()
        ).accessToken()
    }

    // The Mac's view after its tunnel opens: the driver dials loopback and the saved host is the pre-tunnel one.
    static let tunnelLoopbackHost = "127.0.0.1"

    private static let keyPadding = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))

    private let ssoTokens: AWSSSOTokenStore
    private let fetchRoleCredentials: RoleCredentialsFetch
    private let fetchGoogleToken: GoogleTokenFetch
    private let now: @Sendable () -> Date

    init(
        ssoTokens: AWSSSOTokenStore = AWSSSOTokenStore(),
        fetchRoleCredentials: @escaping RoleCredentialsFetch = IAMPasswordMint.liveRoleCredentials,
        fetchGoogleToken: @escaping GoogleTokenFetch = IAMPasswordMint.liveGoogleToken,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ssoTokens = ssoTokens
        self.fetchRoleCredentials = fetchRoleCredentials
        self.fetchGoogleToken = fetchGoogleToken
        self.now = now
    }

    func password(
        for connection: DatabaseConnection,
        method: IAMSignIn,
        secureStore: any SecureStore
    ) async throws -> String {
        switch method {
        case .awsAccessKey:
            return try sign(connection, with: Self.accessKeyCredentials(for: connection, in: secureStore))
        case .awsProfile:
            return try sign(connection, with: Self.profileCredentials(for: connection, in: secureStore))
        case .awsSSO:
            let credentials = try await ssoCredentials(for: connection, in: secureStore)
            return try sign(connection, with: credentials)
        case .googleServiceAccount:
            let value = try secureStore.retrieve(
                forKey: ConnectionSecretKind.gcpServiceAccountKey.account(for: connection.id)
            )
            return try await fetchGoogleToken(Self.serviceAccountKey(value, whenMissing: .serviceAccountKeyMissing))
        case .googleApplicationDefault:
            let device = try DeviceIAMCredentials.load(for: connection.id, from: secureStore)
            return try await fetchGoogleToken(
                Self.serviceAccountKey(device.serviceAccountKey, whenMissing: .applicationDefaultNeedsDeviceKey)
            )
        }
    }

    static func target(for connection: DatabaseConnection) -> AWSIAMTokenTarget {
        if IAMSignIn.engine(for: connection.type)?.awsService == .elastiCache {
            let saved = DriverSSLConfiguration(sslEnabled: connection.sslEnabled, configuration: connection.sslConfiguration)
            return .elastiCache(host: connection.host, tlsDisabled: !saved.isEnabled)
        }
        let defaultPort = Int(connection.type.defaultPort) ?? connection.port
        guard connection.sshEnabled, connection.sshConfiguration != nil else {
            return .rds(
                configuredHost: connection.host,
                configuredPort: connection.port,
                preTunnelHost: nil,
                preTunnelPort: nil,
                defaultPort: defaultPort
            )
        }
        return .rds(
            configuredHost: tunnelLoopbackHost,
            configuredPort: connection.port,
            preTunnelHost: connection.host,
            preTunnelPort: connection.port,
            defaultPort: defaultPort
        )
    }

    static func serviceAccountKey(
        _ value: String?,
        whenMissing missing: IAMSignInError
    ) throws -> GoogleServiceAccountKey {
        guard let value, !value.trimmingCharacters(in: keyPadding).isEmpty else { throw missing }
        do {
            return try GoogleServiceAccountKey.parse(fieldValue: value, readFile: { _ in nil })
        } catch GoogleAuthError.credentialFileUnreadable {
            throw IAMSignInError.serviceAccountKeyIsMacFile
        }
    }

    private func sign(_ connection: DatabaseConnection, with credentials: AWSCredentials) throws -> String {
        try Self.target(for: connection).token(
            username: connection.username,
            fields: connection.additionalFields,
            credentials: credentials,
            now: now()
        )
    }

    private static func accessKeyCredentials(
        for connection: DatabaseConnection,
        in secureStore: any SecureStore
    ) throws -> AWSCredentials {
        let accessKeyId = connection.additionalFields[IAMSignIn.Field.accessKeyId] ?? ""
        let secretAccessKey = try Self.secret(.awsSecretAccessKey, of: connection, in: secureStore) ?? ""
        guard !accessKeyId.isEmpty, !secretAccessKey.isEmpty else { throw IAMSignInError.accessKeyMissing }
        return AWSCredentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: try Self.secret(.awsSessionToken, of: connection, in: secureStore)
        )
    }

    private static func profileCredentials(
        for connection: DatabaseConnection,
        in secureStore: any SecureStore
    ) throws -> AWSCredentials {
        let device = try DeviceIAMCredentials.load(for: connection.id, from: secureStore)
        guard let credentials = device.awsCredentials else {
            throw IAMSignInError.profileNeedsDeviceKey(profile: profileName(of: connection))
        }
        return credentials
    }

    private func ssoCredentials(
        for connection: DatabaseConnection,
        in secureStore: any SecureStore
    ) async throws -> AWSCredentials {
        let device = try DeviceIAMCredentials.load(for: connection.id, from: secureStore)
        guard let settings = device.ssoSettings else { throw IAMSignInError.ssoNotSetUp }
        guard let token = ssoTokens.token(startUrl: settings.startUrl), token.expiresAt > now() else {
            throw IAMSignInError.ssoSignInRequired
        }
        do {
            return try await fetchRoleCredentials(token.accessToken, settings, Self.profileName(of: connection))
        } catch AWSSSOError.sessionUnauthorized {
            ssoTokens.clear(startUrl: settings.startUrl)
            throw IAMSignInError.ssoSignInRequired
        }
    }

    private static func profileName(of connection: DatabaseConnection) -> String {
        nonEmpty(connection.additionalFields[IAMSignIn.Field.profileName]) ?? "default"
    }

    private static func secret(
        _ kind: ConnectionSecretKind,
        of connection: DatabaseConnection,
        in secureStore: any SecureStore
    ) throws -> String? {
        nonEmpty(try secureStore.retrieve(forKey: kind.account(for: connection.id)))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
