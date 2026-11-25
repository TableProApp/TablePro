import Foundation
import TableProFFI
@testable import TableProMobile
import Testing

// Stands in for ASWebAuthenticationSession: keeps the page the core opened, then the person closes it.
@MainActor
private final class ClosedPage: WebAuthenticating {
    private(set) var asked: [(url: URL, scheme: String)] = []

    func authenticate(url: URL, callbackScheme: String) async throws(AccountError) -> URL {
        asked.append((url, callbackScheme))
        throw .canceled
    }
}

// The core's iOS slice in the app, through the adapter the Mac shares, with the config the app opens it with.
@MainActor
struct AccountCoreSignInTests {
    private static let device = MobileAccountSetup.Device(name: "Ada's iPhone", appVersion: "1.4", osVersion: "iOS 26.1")

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func backend(in folder: URL, managed: ManagedAppConfiguration = .unmanaged) -> CoreAccountBackend {
        CoreAccountBackend(
            config: MobileAccountSetup.config(
                deviceID: String(repeating: "5f", count: 32),
                device: Self.device,
                accountFolder: folder,
                managed: managed,
                developmentStack: nil
            ),
            appVersion: Self.device.appVersion,
            keychain: MobileAccountKeychain(items: AccountKeychainItems(items: InMemoryKeychainItems(), accessGroup: nil))
        )
    }

    @Test("An iPhone signs in to tablepro.app as the iOS client, through the Mac's scheme, and a closed page cancels")
    func signsInAsTheIOSClient() async throws {
        let backend = backend(in: try folder())
        let page = ClosedPage()
        await backend.waitUntilRestored()

        await #expect(throws: AccountError.canceled) { try await backend.signIn(using: page) }

        let opened = try #require(page.asked.first)
        let query = URLComponents(url: opened.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(opened.scheme == "app.tablepro")
        #expect(opened.url.absoluteString.hasPrefix("https://account.tablepro.app/oauth/authorize?"))
        #expect(query.first { $0.name == "client_id" }?.value == "tablepro-ios")
        #expect(query.first { $0.name == "redirect_uri" }?.value == "app.tablepro:/oauth/callback")
        #expect(backend.status().state == .signedOut)
        #expect(backend.machineID == String(repeating: "5f", count: 32))
    }

    @Test("A managed server that allows no other holds the account, and a choice is refused")
    func managedServerHolds() async throws {
        let backend = backend(
            in: try folder(),
            managed: ManagedAppConfiguration(accountServerURL: "https://127.0.0.1:1", allowOtherAccountServers: false)
        )
        await backend.waitUntilRestored()

        let server = backend.server()
        await #expect(throws: AccountError.companyServer(.managed)) {
            try await backend.chooseServer(URL(string: "https://tablepro.example.com"))
        }
        #expect(server.isManaged && !server.othersAllowed && !server.isProduction)
        #expect(server.apiOrigin.absoluteString == "https://127.0.0.1:1")
    }

    @Test("The config names the iOS client, the device's system with its version, and no file from before the core")
    func config() {
        let config = MobileAccountSetup.config(
            deviceID: "id",
            device: Self.device,
            accountFolder: URL(fileURLWithPath: "/data/Account", isDirectory: true),
            managed: ManagedAppConfiguration(accountServerURL: "https://tablepro.example.com"),
            developmentStack: nil
        )

        #expect(config.client == .ios)
        #expect(config.machineId == "id")
        #expect(config.osVersion == "iOS 26.1")
        #expect(config.accountFile == "/data/Account/account.json")
        #expect(config.managedServerUrl == "https://tablepro.example.com")
        #expect(config.allowOtherServers == nil)
        #expect(config.legacyEntitlementFile == nil)
        #expect(config.accountUrl == nil && config.apiUrl == nil)
    }
}
