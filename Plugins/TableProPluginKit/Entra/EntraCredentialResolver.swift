import Foundation

/// Turns a connection's Entra ID fields into an access token for Azure SQL.
///
/// An actor so that several connections opening at once against the same directory share one
/// refresh instead of racing, which would burn the rotated refresh token and sign the user out.
public actor EntraCredentialResolver {
    public static let shared = EntraCredentialResolver()

    private let store: EntraTokenStoring
    private var refreshTasks: [String: Task<EntraStoredToken, Error>] = [:]

    public init(store: EntraTokenStoring = EntraKeychainTokenStore.shared) {
        self.store = store
    }

    nonisolated public static func cacheKey(tenantId: String, clientId: String) -> String {
        "\(tenantId)|\(clientId)"
    }

    nonisolated public static func cacheKey(fields: [String: String]) -> String {
        cacheKey(
            tenantId: EntraAppRegistration.tenantId(from: fields),
            clientId: EntraAppRegistration.clientId(from: fields)
        )
    }

    /// A token ready to hand to the driver, refreshed if it is close to expiry.
    ///
    /// Throws `EntraOAuthError` with `needsSignIn` true when only an interactive sign-in can
    /// recover. The MSSQL driver lets that type propagate so the host can offer the browser flow.
    public func accessToken(
        fields: [String: String],
        session: URLSession = .shared,
        now: Date = Date()
    ) async throws -> String {
        let clientId = EntraAppRegistration.clientId(from: fields)
        guard !clientId.isEmpty else { throw EntraOAuthError.notConfigured }
        let tenantId = EntraAppRegistration.tenantId(from: fields)
        let key = Self.cacheKey(tenantId: tenantId, clientId: clientId)

        guard let stored = store.load(key: key) else {
            throw EntraOAuthError.signInRequired
        }
        if stored.isFresh(asOf: now) {
            return stored.accessToken
        }
        guard let refreshToken = stored.refreshToken, !refreshToken.isEmpty else {
            throw EntraOAuthError.signInRequired
        }

        let refreshed = try await refresh(
            key: key,
            tenantId: tenantId,
            clientId: clientId,
            refreshToken: refreshToken,
            previous: stored,
            session: session
        )
        return refreshed.accessToken
    }

    /// Runs the device code flow and stores the result. `presentCode` receives the verification
    /// URL and the code the user types into it.
    public func signIn(
        fields: [String: String],
        presentCode: @escaping @Sendable (URL, String) -> Void,
        session: URLSession = .shared
    ) async throws {
        let clientId = EntraAppRegistration.clientId(from: fields)
        guard !clientId.isEmpty else { throw EntraOAuthError.notConfigured }
        let tenantId = EntraAppRegistration.tenantId(from: fields)

        let token = try await EntraOAuth.signIn(
            tenantId: tenantId,
            clientId: clientId,
            openVerificationURL: presentCode,
            session: session
        )
        store.save(
            EntraStoredToken(token),
            key: Self.cacheKey(tenantId: tenantId, clientId: clientId)
        )
    }

    public func signOut(fields: [String: String]) {
        store.clear(key: Self.cacheKey(fields: fields))
    }

    private func refresh(
        key: String,
        tenantId: String,
        clientId: String,
        refreshToken: String,
        previous: EntraStoredToken,
        session: URLSession
    ) async throws -> EntraStoredToken {
        if let inFlight = refreshTasks[key] {
            return try await inFlight.value
        }
        let task = Task<EntraStoredToken, Error> {
            let token = try await EntraOAuth.refresh(
                tenantId: tenantId,
                clientId: clientId,
                refreshToken: refreshToken,
                session: session
            )
            // Entra rotates refresh tokens, but a response without one must not blank the
            // stored value or the next connect would need an interactive sign-in.
            let stored = EntraStoredToken(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken?.isEmpty == false
                    ? token.refreshToken
                    : previous.refreshToken,
                expiresAt: token.expiresAt
            )
            store.save(stored, key: key)
            return stored
        }
        refreshTasks[key] = task
        defer { refreshTasks[key] = nil }

        do {
            return try await task.value
        } catch let error as EntraOAuthError where error.needsSignIn {
            store.clear(key: key)
            throw error
        }
    }
}
