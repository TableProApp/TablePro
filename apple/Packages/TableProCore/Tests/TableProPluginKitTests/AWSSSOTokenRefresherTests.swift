import Foundation
@testable import TableProPluginKit
import Testing

struct AWSSSOTokenRefresherTests {
    static let now = Date(timeIntervalSince1970: 1_900_000_000)
    static let startUrl = "https://example.awsapps.com/start"

    @Test("A token inside the refresh window is refreshed with the refresh token and saved")
    func refreshesNearExpiry() async throws {
        let script = refreshScript(.json(#"{"accessToken":"AT2","expiresIn":3600,"refreshToken":"RT2","tokenType":"Bearer"}"#))
        let store = MemoryTokenStore()
        let stored = entry(expiresIn: 10 * 60)

        let current = await AWSSSOTokenRefresher().current(
            stored, key: "work", store: store, session: AWSSSOScriptedProtocol.session(for: script), now: Self.now
        )

        #expect(current.accessToken == "AT2")
        #expect(current.refreshToken == "RT2")
        #expect(current.expiresAt == Self.now.addingTimeInterval(3_600))
        #expect(current.clientId == "CID")
        #expect(current.registrationExpiresAt == stored.registrationExpiresAt)
        #expect(store.saved(key: "work") == current)
        let call = try #require(script.calls(to: "/token").first)
        #expect(call.request.url?.host == "oidc.eu-west-1.amazonaws.com")
        #expect(try jsonStrings(call.body) == [
            "clientId": "CID",
            "clientSecret": "CSECRET",
            "grantType": "refresh_token",
            "refreshToken": "RT"
        ])
    }

    @Test("An expired token is refreshed too, and a reply without a refresh token keeps the old one")
    func refreshesExpiredAndKeepsRefreshToken() async {
        let script = refreshScript(.json(#"{"accessToken":"AT2","expiresIn":3600,"tokenType":"Bearer"}"#))
        let current = await AWSSSOTokenRefresher().current(
            entry(expiresIn: -60), key: "work", store: MemoryTokenStore(),
            session: AWSSSOScriptedProtocol.session(for: script), now: Self.now
        )
        #expect(current.accessToken == "AT2")
        #expect(current.refreshToken == "RT")
    }

    @Test("A token with more than 15 minutes left is used as stored, with no request")
    func leavesFreshTokenAlone() async {
        let script = refreshScript(.json("{}"))
        let stored = entry(expiresIn: 16 * 60)
        let current = await AWSSSOTokenRefresher().current(
            stored, key: "work", store: MemoryTokenStore(),
            session: AWSSSOScriptedProtocol.session(for: script), now: Self.now
        )
        #expect(current == stored)
        #expect(script.exchanges.isEmpty)
    }

    @Test(
        "A token that cannot refresh is used as stored, with no request",
        arguments: [
            AWSSSOTokenCacheEntry(accessToken: "AT", expiresAt: AWSSSOTokenRefresherTests.now, region: "eu-west-1", startUrl: AWSSSOTokenRefresherTests.startUrl),
            AWSSSOTokenCacheEntry(
                accessToken: "AT", expiresAt: AWSSSOTokenRefresherTests.now, region: "eu-west-1", startUrl: AWSSSOTokenRefresherTests.startUrl,
                refreshToken: "RT", clientId: "CID", clientSecret: "CSECRET",
                registrationExpiresAt: AWSSSOTokenRefresherTests.now.addingTimeInterval(-1)
            ),
            AWSSSOTokenCacheEntry(
                accessToken: "AT", expiresAt: AWSSSOTokenRefresherTests.now, region: "eu-west-1", startUrl: AWSSSOTokenRefresherTests.startUrl,
                refreshToken: "RT", clientId: "CID", clientSecret: "CSECRET"
            )
        ]
    )
    func skipsWithoutRefreshMaterial(stored: AWSSSOTokenCacheEntry) async {
        let script = refreshScript(.json("{}"))
        let current = await AWSSSOTokenRefresher().current(
            stored, key: "work", store: MemoryTokenStore(),
            session: AWSSSOScriptedProtocol.session(for: script), now: Self.now
        )
        #expect(current == stored)
        #expect(script.exchanges.isEmpty)
    }

    @Test("A refused refresh keeps the stored token")
    func failedRefreshKeepsStored() async {
        let refused = refreshScript(.json(#"{"error":"invalid_grant"}"#, status: 400))
        let stored = entry(expiresIn: 5 * 60)
        let store = MemoryTokenStore()

        let kept = await AWSSSOTokenRefresher().current(
            stored, key: "work", store: store, session: AWSSSOScriptedProtocol.session(for: refused), now: Self.now
        )

        #expect(kept == stored)
        #expect(store.saved(key: "work") == nil)
        #expect(refused.calls(to: "/token").count == 1)
    }

    @Test("A refresh refused because the AWS CLI rotated the refresh token meanwhile takes the CLI's token")
    func failedRefreshTakesTokenSavedMeanwhile() async {
        let store = MemoryTokenStore()
        let newer = entry(expiresIn: 8 * 3_600, accessToken: "FROM-CLI")
        let refused = AWSSSOScriptedProtocol.Script { _, _ in
            store.preload(newer, key: "work")
            return .json(#"{"error":"invalid_grant"}"#, status: 400)
        }

        let current = await AWSSSOTokenRefresher().current(
            entry(expiresIn: 5 * 60), key: "work", store: store,
            session: AWSSSOScriptedProtocol.session(for: refused), now: Self.now
        )

        #expect(current == newer)
    }

    @Test("A sign-in that finishes while a refresh is out keeps its session")
    func signInDuringRefreshWins() async {
        let store = MemoryTokenStore()
        let signedIn = AWSSSOTokenCacheEntry(
            accessToken: "NEW-SESSION", expiresAt: Self.now.addingTimeInterval(8 * 3_600), region: "eu-west-1",
            startUrl: Self.startUrl, refreshToken: "RT-NEW", clientId: "CID-NEW", clientSecret: "CSECRET-NEW",
            registrationExpiresAt: Self.now.addingTimeInterval(80 * 86_400)
        )
        let script = AWSSSOScriptedProtocol.Script { _, _ in
            store.preload(signedIn, key: "work")
            return .json(#"{"accessToken":"AT2","expiresIn":3600,"refreshToken":"RT2"}"#)
        }

        let current = await AWSSSOTokenRefresher().current(
            entry(expiresIn: 60), key: "work", store: store,
            session: AWSSSOScriptedProtocol.session(for: script), now: Self.now
        )

        #expect(current == signedIn)
        #expect(store.saved(key: "work") == nil)
    }

    @Test("A refreshed token the store refuses is kept and saved on the next connect, with no second refresh")
    func unsavedRefreshIsKept() async {
        let script = refreshScript(.json(#"{"accessToken":"AT2","expiresIn":3600,"refreshToken":"RT2"}"#))
        let session = AWSSSOScriptedProtocol.session(for: script)
        let refresher = AWSSSOTokenRefresher()
        let store = MemoryTokenStore(failingSaves: 1)
        let stored = entry(expiresIn: 60)

        let first = await refresher.current(stored, key: "work", store: store, session: session, now: Self.now)
        let second = await refresher.current(stored, key: "work", store: store, session: session, now: Self.now)

        #expect(first.refreshToken == "RT2")
        #expect(second == first)
        #expect(store.saved(key: "work") == first)
        #expect(script.calls(to: "/token").count == 1)
    }

    @Test("A token another caller already refreshed is taken from the store, with no request")
    func takesTokenRefreshedSinceRead() async {
        let script = refreshScript(.json("{}"))
        let store = MemoryTokenStore()
        let newer = entry(expiresIn: 8 * 3_600, accessToken: "AT2")
        store.preload(newer, key: "work")

        let current = await AWSSSOTokenRefresher().current(
            entry(expiresIn: 60), key: "work", store: store,
            session: AWSSSOScriptedProtocol.session(for: script), now: Self.now
        )

        #expect(current == newer)
        #expect(script.exchanges.isEmpty)
    }

    @Test("Connections opening at once share one refresh, since the first one rotates the refresh token")
    func concurrentCallsShareOneRefresh() async {
        let script = refreshScript(.json(#"{"accessToken":"AT2","expiresIn":3600,"refreshToken":"RT2"}"#))
        let session = AWSSSOScriptedProtocol.session(for: script)
        let refresher = AWSSSOTokenRefresher()
        let store = MemoryTokenStore()
        let stored = entry(expiresIn: 60)

        async let first = refresher.current(stored, key: "work", store: store, session: session, now: Self.now)
        async let second = refresher.current(stored, key: "work", store: store, session: session, now: Self.now)
        let accessTokens = await [first.accessToken, second.accessToken]

        #expect(accessTokens == ["AT2", "AT2"])
        #expect(script.calls(to: "/token").count == 1)
    }

    @Test("The Mac reads the CLI cache, refreshes it in place and returns the new token")
    func macCacheRefreshesInPlace() async throws {
        let directory = NSTemporaryDirectory() + "AWSSSOTokenRefresherTests_\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = fileStore(directory)
        try AWSSSOLogin.writeTokenCache(cacheKey: "work", entry: entry(expiresIn: -60), cacheDirectory: directory)
        let script = refreshScript(.json(#"{"accessToken":"AT2","expiresIn":3600,"refreshToken":"RT2"}"#))

        let token = try await AWSSSO.accessToken(
            store: store, refresher: AWSSSOTokenRefresher(),
            session: AWSSSOScriptedProtocol.session(for: script), now: Self.now
        )

        #expect(token == "AT2")
        let cached = try #require(try store.load(key: "work"))
        #expect(cached.accessToken == "AT2")
        #expect(cached.refreshToken == "RT2")
        #expect(cached.clientSecret == "CSECRET")
    }

    @Test("The Mac still asks for a sign-in when the cache cannot refresh")
    func macCacheExpiredWithoutRefreshToken() async throws {
        let directory = NSTemporaryDirectory() + "AWSSSOTokenRefresherTests_\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = fileStore(directory)
        let script = refreshScript(.json("{}"))
        let session = AWSSSOScriptedProtocol.session(for: script)

        await #expect(throws: AWSSSOError.tokenCacheNotFound(profile: "dev")) {
            _ = try await AWSSSO.accessToken(store: store, session: session, now: Self.now)
        }
        try AWSSSOLogin.writeTokenCache(
            cacheKey: "work",
            entry: AWSSSOTokenCacheEntry(
                accessToken: "AT", expiresAt: Self.now.addingTimeInterval(-60), region: "eu-west-1", startUrl: Self.startUrl
            ),
            cacheDirectory: directory
        )
        await #expect(throws: AWSSSOError.tokenExpired(profile: "dev")) {
            _ = try await AWSSSO.accessToken(store: store, session: session, now: Self.now)
        }
        #expect(script.exchanges.isEmpty)
    }

    @Test("The CLI's own cache file, with its timestamp format, reads with every refresh field")
    func readsCLICacheFile() throws {
        let directory = NSTemporaryDirectory() + "AWSSSOTokenRefresherTests_\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let cli = """
        {"startUrl": "https://example.awsapps.com/start", "region": "eu-west-1", "accessToken": "AT",
         "expiresAt": "2030-03-17T17:46:40Z", "clientId": "CID", "clientSecret": "CSECRET",
         "registrationExpiresAt": "2030-06-01T00:00:00Z", "refreshToken": "RT"}
        """
        let path = (directory as NSString).appendingPathComponent(AWSSSO.sha1Hex(Data("work".utf8)) + ".json")
        try Data(cli.utf8).write(to: URL(fileURLWithPath: path))

        let loaded = try #require(try fileStore(directory).load(key: "work"))

        #expect(loaded.expiresAt == Self.now)
        #expect(loaded.refreshToken == "RT")
        #expect(loaded.registrationExpiresAt == ISO8601DateFormatter().date(from: "2030-06-01T00:00:00Z"))
        #expect(loaded.canRefresh(at: Self.now))
    }

    private func entry(expiresIn: TimeInterval, accessToken: String = "AT") -> AWSSSOTokenCacheEntry {
        AWSSSOTokenCacheEntry(
            accessToken: accessToken,
            expiresAt: Self.now.addingTimeInterval(expiresIn),
            region: "eu-west-1",
            startUrl: Self.startUrl,
            refreshToken: "RT",
            clientId: "CID",
            clientSecret: "CSECRET",
            registrationExpiresAt: Self.now.addingTimeInterval(80 * 86_400)
        )
    }

    private func fileStore(_ directory: String) -> AWSSSOFileTokenStore {
        AWSSSOFileTokenStore(
            cacheDirectory: directory,
            settings: AWSSSOProfileSettings(
                accountId: "111111111111", roleName: "Developer", startUrl: Self.startUrl,
                region: "eu-west-1", ssoSession: "work"
            ),
            profileName: "dev"
        )
    }

    private func refreshScript(_ reply: AWSSSOScriptedProtocol.Reply) -> AWSSSOScriptedProtocol.Script {
        AWSSSOScriptedProtocol.Script { request, _ in
            request.url?.path == "/token" ? reply : .json(#"{"error":"not_found"}"#, status: 404)
        }
    }

    private func jsonStrings(_ data: Data) throws -> [String: String] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
    }
}

private final class MemoryTokenStore: AWSSSOTokenStoring, @unchecked Sendable {
    struct SaveFailure: Error {}

    private let lock = NSLock()
    private var entries: [String: AWSSSOTokenCacheEntry] = [:]
    private var saves: [String: AWSSSOTokenCacheEntry] = [:]
    private var failingSaves: Int

    init(failingSaves: Int = 0) {
        self.failingSaves = failingSaves
    }

    func preload(_ entry: AWSSSOTokenCacheEntry, key: String) {
        lock.withLock { entries[key] = entry }
    }

    func saved(key: String) -> AWSSSOTokenCacheEntry? {
        lock.withLock { saves[key] }
    }

    func load(key: String) throws -> AWSSSOTokenCacheEntry? {
        lock.withLock { entries[key] }
    }

    func save(_ entry: AWSSSOTokenCacheEntry, key: String) throws {
        try lock.withLock {
            if failingSaves > 0 {
                failingSaves -= 1
                throw SaveFailure()
            }
            entries[key] = entry
            saves[key] = entry
        }
    }
}
