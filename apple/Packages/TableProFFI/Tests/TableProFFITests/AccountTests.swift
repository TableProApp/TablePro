import Foundation
import TableProFFI
import Testing

// The Keychain as the core reaches it: one item per secret, noting which items it asked for.
private final class KeychainItems: HostSecrets, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SecretItemTag: String] = [:]
    private var asked: [SecretItemTag] = []

    func load(connectionId: String, kind: SecretKindTag) throws -> String? { nil }
    func store(connectionId: String, kind: SecretKindTag, secret: String, label: String) throws {}
    func relabel(connectionId: String, kind: SecretKindTag, label: String) throws {}
    func delete(connectionId: String, kind: SecretKindTag) throws {}
    func deleteConnection(connectionId: String) throws {}

    func loadItem(item: SecretItemTag) throws -> String? {
        lock.withLock {
            asked.append(item)
            return items[item]
        }
    }

    func storeItem(item: SecretItemTag, secret: String) throws {
        lock.withLock { items[item] = secret }
    }

    func deleteItem(item: SecretItemTag) throws {
        lock.withLock { _ = items.removeValue(forKey: item) }
    }

    var askedFor: [SecretItemTag] {
        lock.withLock { asked }
    }
}

private final class Quiet: AccountListener, Sendable {
    func statusChanged() {}
    func signedOut(cause: SignOutCauseTag) {}
}

// Hands each status change to the test, which awaits the first one the restore makes.
private final class Changes: AccountListener, Sendable {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func statusChanged() {
        continuation.yield()
    }

    func signedOut(cause: SignOutCauseTag) {}
}

private final class NoBrowser: HostBrowser, Sendable {
    func openUrl(url: String) throws {
        throw HostBrowserError.Failed(detail: "the Mac signs in through its web session")
    }
}

// Stands in for ASWebAuthenticationSession, closed by the person before the page answers.
private final class ClosedSession: HostWebAuthenticator, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [(url: String, scheme: String)] = []

    func authenticate(url: String, callbackScheme: String) throws -> String {
        lock.withLock { pages.append((url, callbackScheme)) }
        throw HostBrowserError.Cancelled
    }

    func cancel() {}

    var asked: [(url: String, scheme: String)] {
        lock.withLock { pages }
    }
}

private let macMachineId = String(repeating: "e4", count: 32)

private func folder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func config(
    in folder: URL,
    managedServerUrl: String? = nil,
    allowOtherServers: Bool? = nil,
    machineId: String = macMachineId,
    accountUrl: String? = nil
) -> AccountConfig {
    AccountConfig(
        accountUrl: accountUrl,
        apiUrl: accountUrl.map { "\($0)/v2" },
        entitlementKeys: [],
        deviceName: "Ada's Mac",
        appVersion: "0.89.0",
        osVersion: "26.1",
        accountFile: folder.appendingPathComponent("account.json").path,
        callbackFinished: "",
        callbackUnknown: "",
        machineGuid: nil,
        client: .macos,
        machineId: machineId,
        managedServerUrl: managedServerUrl,
        allowOtherServers: allowOtherServers,
        legacyEntitlementFile: folder.appendingPathComponent("Account/entitlement.jwt").path,
        licenseKeys: []
    )
}

private func code(of error: any Error) -> String? {
    guard case CoreError.Failed(let info) = error else { return nil }
    return info.code
}

@Test func aMacSignsInAsTheMacClientThroughItsWebSessionAndAClosedSessionCancels() async throws {
    let core = try Core(config: HostConfig(clientVersion: "test", storageDir: nil), secrets: KeychainItems())
    let session = ClosedSession()
    let account = try await core.openAccount(
        config: config(in: try folder()), browser: NoBrowser(), webAuthenticator: session, listener: Quiet()
    )

    await #expect(throws: CoreError.Cancelled) { try await account.signIn(cancel: nil) }

    let page = try #require(session.asked.first)
    #expect(page.scheme == "app.tablepro")
    #expect(page.url.hasPrefix("https://account.tablepro.app/oauth/authorize?"))
    #expect(page.url.contains("client_id=tablepro-macos"))
    #expect(page.url.contains("redirect_uri=app.tablepro%3A%2Foauth%2Fcallback"))
    let server = account.server()
    #expect(server.isProduction && !server.isManaged && server.othersAllowed)
    #expect(server.apiOrigin == "https://api.tablepro.app")
    #expect(account.status().state == .signedOut)
}

@Test func aManagedServerThatAllowsNoOtherHoldsTheMac() async throws {
    let core = try Core(config: HostConfig(clientVersion: "test", storageDir: nil), secrets: KeychainItems())
    let account = try await core.openAccount(
        config: config(in: try folder(), managedServerUrl: "https://127.0.0.1:1", allowOtherServers: false),
        browser: NoBrowser(),
        webAuthenticator: ClosedSession(),
        listener: Quiet()
    )

    let server = account.server()
    var refused: (any Error)?
    do {
        try await account.chooseServer(url: "https://api.example.com")
    } catch {
        refused = error
    }

    #expect(server.isManaged && !server.othersAllowed && !server.isProduction)
    #expect(server.apiOrigin == "https://127.0.0.1:1")
    #expect(refused.flatMap(code(of:)) == "account.server_managed")
    #expect(account.license() == nil)
}

@Test func aReleaseBuildRefusesADevelopmentServerAndAMachineIdThatIsNotTheMacs() async throws {
    let core = try Core(config: HostConfig(clientVersion: "test", storageDir: nil), secrets: KeychainItems())
    var errors: [String?] = []
    for config in [
        config(in: try folder(), accountUrl: "http://127.0.0.1:5284"),
        config(in: try folder(), machineId: "not hex")
    ] {
        do {
            _ = try await core.openAccount(
                config: config, browser: NoBrowser(), webAuthenticator: ClosedSession(), listener: Quiet()
            )
            errors.append(nil)
        } catch {
            errors.append(code(of: error))
        }
    }

    #expect(errors == ["ffi.account_config", "account.no_machine_id"])
}

@Test func theMacsOldEntitlementWithNoKeychainTokenLeavesItSignedOutAndTheFileGoes() async throws {
    let keychain = KeychainItems()
    let core = try Core(config: HostConfig(clientVersion: "test", storageDir: nil), secrets: keychain)
    let folder = try folder()
    let old = folder.appendingPathComponent("Account/entitlement.jwt")
    try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("header.claims.signature\n".utf8).write(to: old)

    let changes = Changes()
    var restored = changes.stream.makeAsyncIterator()

    let account = try await core.openAccount(
        config: config(in: folder), browser: NoBrowser(), webAuthenticator: ClosedSession(), listener: changes
    )
    _ = await restored.next()

    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(keychain.askedFor == [.accountRefreshToken])
    #expect(account.status().state == .signedOut)
}
