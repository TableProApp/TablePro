import Foundation
import os

public protocol AWSSSOTokenStoring: Sendable {
    func load(key: String) throws -> AWSSSOTokenCacheEntry?
    func save(_ entry: AWSSSOTokenCacheEntry, key: String) throws
}

// An actor so that connections opening at once on one IAM Identity Center session share a refresh,
// since a second call with the same refresh token can fail once the first rotated it.
public actor AWSSSOTokenRefresher {
    public static let shared = AWSSSOTokenRefresher()

    // The AWS CLI refreshes when less than this is left (botocore SSOTokenProvider._REFRESH_WINDOW).
    static let refreshWindow: TimeInterval = 15 * 60

    private static let logger = Logger(subsystem: "com.TablePro", category: "AWSSSOTokenRefresher")

    private var inFlight: [String: Task<AWSSSOTokenCacheEntry, Error>] = [:]
    // A refresh the store could not take; dropping it would lose the rotated refresh token.
    private var unsaved: [String: AWSSSOTokenCacheEntry] = [:]

    public init() {}

    // A failed refresh keeps the stored token, as the AWS CLI does; the caller checks its expiry.
    public func current(
        _ stored: AWSSSOTokenCacheEntry,
        key: String,
        store: any AWSSSOTokenStoring,
        session: URLSession = AWSHTTP.shared,
        now: Date = Date()
    ) async -> AWSSSOTokenCacheEntry {
        // A sign-in, another connection or the AWS CLI may have written since the caller read it.
        var loaded = try? store.load(key: key)
        var token = loaded ?? stored
        if let kept = unsaved[key], kept.clientId == token.clientId, kept.expiresAt > token.expiresAt {
            token = kept
            if (try? store.save(kept, key: key)) != nil {
                unsaved[key] = nil
                loaded = try? store.load(key: key)
            }
        }
        guard token.expiresAt.timeIntervalSince(now) < Self.refreshWindow, token.canRefresh(at: now) else {
            return token
        }
        do {
            return try await refresh(token, key: key, store: store, loaded: loaded, session: session, now: now)
        } catch {
            Self.logger.error("Refreshing the IAM Identity Center token failed: \(error.localizedDescription, privacy: .private)")
            if let latest = try? store.load(key: key), latest != loaded {
                return latest
            }
            return token
        }
    }

    private func refresh(
        _ token: AWSSSOTokenCacheEntry,
        key: String,
        store: any AWSSSOTokenStoring,
        loaded: AWSSSOTokenCacheEntry?,
        session: URLSession,
        now: Date
    ) async throws -> AWSSSOTokenCacheEntry {
        if let task = inFlight[key] {
            return try await task.value
        }
        let task = Task<AWSSSOTokenCacheEntry, Error> {
            let refreshed = try await AWSSSOLogin.refresh(token, session: session, now: now)
            // A sign-in that finished meanwhile wins over a refresh of the session it replaced.
            if let latest = try? store.load(key: key), latest != loaded {
                return latest
            }
            do {
                try store.save(refreshed, key: key)
            } catch {
                Self.logger.error("Saving the refreshed IAM Identity Center token failed: \(error.localizedDescription, privacy: .private)")
                unsaved[key] = refreshed
            }
            return refreshed
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}

extension AWSSSOTokenCacheEntry {
    func canRefresh(at now: Date) -> Bool {
        guard refreshToken?.isEmpty == false, clientId?.isEmpty == false, clientSecret?.isEmpty == false,
              let registrationExpiresAt else { return false }
        return registrationExpiresAt > now
    }
}

extension AWSSSOLogin {
    static func refresh(
        _ entry: AWSSSOTokenCacheEntry,
        session: URLSession,
        now: Date = Date()
    ) async throws -> AWSSSOTokenCacheEntry {
        guard let refreshToken = entry.refreshToken, let clientId = entry.clientId,
              let clientSecret = entry.clientSecret else {
            throw AWSSSOLoginError.unexpectedResponse
        }
        let body: [String: Any] = [
            "clientId": clientId,
            "clientSecret": clientSecret,
            "grantType": "refresh_token",
            "refreshToken": refreshToken
        ]
        let data = try await post(path: "token", region: entry.region, body: body, session: session)
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AWSSSOLoginError.unexpectedResponse
        }
        return AWSSSOTokenCacheEntry(
            accessToken: token.accessToken,
            expiresAt: now.addingTimeInterval(TimeInterval(token.expiresIn)),
            region: entry.region,
            startUrl: entry.startUrl,
            // A response without one keeps the old, as botocore keeps the registration.
            refreshToken: token.refreshToken?.isEmpty == false ? token.refreshToken : refreshToken,
            clientId: clientId,
            clientSecret: clientSecret,
            registrationExpiresAt: entry.registrationExpiresAt
        )
    }
}

extension AWSSSO {
    static func accessToken(
        store: AWSSSOFileTokenStore,
        refresher: AWSSSOTokenRefresher = .shared,
        session: URLSession,
        now: Date = Date()
    ) async throws -> String {
        guard let stored = try store.load(key: store.key) else {
            throw AWSSSOError.tokenCacheNotFound(profile: store.profileName)
        }
        let token = await refresher.current(stored, key: store.key, store: store, session: session, now: now)
        guard token.expiresAt > now else {
            throw AWSSSOError.tokenExpired(profile: store.profileName)
        }
        return token.accessToken
    }
}

// The AWS CLI's ~/.aws/sso/cache file for one sso-session or legacy start URL.
struct AWSSSOFileTokenStore: AWSSSOTokenStoring {
    let cacheDirectory: String
    let settings: AWSSSOProfileSettings
    let profileName: String

    var key: String {
        settings.ssoSession ?? settings.startUrl
    }

    func load(key: String) throws -> AWSSSOTokenCacheEntry? {
        let path = (cacheDirectory as NSString).appendingPathComponent(AWSSSO.sha1Hex(Data(key.utf8)) + ".json")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }

        struct TokenCache: Decodable {
            let accessToken: String
            let expiresAt: String
            let region: String?
            let startUrl: String?
            let refreshToken: String?
            let clientId: String?
            let clientSecret: String?
            let registrationExpiresAt: String?
        }

        guard let cache = try? JSONDecoder().decode(TokenCache.self, from: data),
              let expiresAt = AWSCredentialResolver.parseISO8601(cache.expiresAt) else {
            throw AWSSSOError.tokenCacheMalformed(profile: profileName)
        }
        return AWSSSOTokenCacheEntry(
            accessToken: cache.accessToken,
            expiresAt: expiresAt,
            region: cache.region ?? settings.region,
            startUrl: cache.startUrl ?? settings.startUrl,
            refreshToken: cache.refreshToken,
            clientId: cache.clientId,
            clientSecret: cache.clientSecret,
            registrationExpiresAt: cache.registrationExpiresAt.flatMap(AWSCredentialResolver.parseISO8601)
        )
    }

    func save(_ entry: AWSSSOTokenCacheEntry, key: String) throws {
        try AWSSSOLogin.writeTokenCache(cacheKey: key, entry: entry, cacheDirectory: cacheDirectory)
    }
}
