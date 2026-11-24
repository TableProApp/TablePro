//
//  CoreAccountMappingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
import Testing

struct CoreAccountMappingTests {
    private static func failure(_ code: String, message: String = "", server: String? = nil) -> CoreError {
        .Failed(info: ErrorInfo(
            code: code,
            codes: [code],
            message: message,
            server: server.map { ServerMessage(message: "", code: $0, sqlstate: nil, detail: nil, hint: nil, position: nil) },
            path: nil,
            secret: nil,
            hostKey: nil,
            tlsFailure: nil,
            ai: nil
        ))
    }

    private static func mapped(_ code: String, _ operation: CoreAccountMapping.Operation = .other) -> AccountError {
        CoreAccountMapping.error(failure(code), during: operation)
    }

    @Test("Each company server refusal reads as the reason the sign-in window words")
    func companyServerRefusals() {
        #expect(Self.mapped("account.server_invalid") == .companyServer(.invalidAddress))
        #expect(Self.mapped("account.server_insecure") == .companyServer(.invalidAddress))
        #expect(Self.mapped("account.server_not_tablepro") == .companyServer(.notATableProServer))
        #expect(Self.mapped("account.server_mismatch") == .companyServer(.notATableProServer))
        #expect(Self.mapped("account.server_managed") == .companyServer(.managed))
        #expect(Self.mapped("account.server_unsupported") == .companyServer(.unsupported))
        #expect(Self.mapped("account.license_not_installed") == .companyServer(.licenseMissing))
        for code in ["account.license_other_server", "account.license_untrusted", "account.license_invalid",
                     "account.license_not_yet_valid"] {
            #expect(Self.mapped(code) == .companyServer(.licenseInvalid), "\(code)")
        }
    }

    @Test("A refused license key is invalid_grant, so a stored key is set aside; a declined sign-in says nothing")
    func refusedSignIns() {
        #expect(Self.mapped("account.sign_in_refused", .licenseKey) == .oauth("invalid_grant", description: nil))
        #expect(Self.mapped("account.sign_in_refused", .signIn).friendlyDescription == nil)
        let declined = CoreAccountMapping.error(
            Self.failure("account.sign_in_refused", message: "the sign-in was refused: access_denied"), during: .signIn
        )
        #expect(declined.friendlyDescription == nil)
        #expect(CoreAccountMapping.error(.Cancelled, during: .signIn) == .canceled)
        #expect(Self.mapped("account.sign_in_canceled", .signIn) == .canceled)
    }

    @Test("Past the device limit a sign-in or a key's exchange stands, with the limit in the status; other refusals do not")
    func deviceLimitKeepsTheSignIn() {
        #expect(CoreAccountMapping.signInError(Self.failure("account.device_limit_reached"), during: .signIn) == nil)
        #expect(CoreAccountMapping.signInError(Self.failure("account.device_limit_reached"), during: .licenseKey) == nil)
        #expect(CoreAccountMapping.signInError(.Cancelled, during: .signIn) == .canceled)
        #expect(CoreAccountMapping.signInError(Self.failure("account.sign_in_refused"), during: .licenseKey)
            == .oauth("invalid_grant", description: nil))
    }

    @Test("A sign-in the server refused for another reason says so instead of closing quietly")
    func otherRefusalsAreWorded() {
        let busy = CoreAccountMapping.error(
            Self.failure("account.sign_in_refused", message: "the sign-in was refused: temporarily_unavailable"), during: .signIn
        )
        #expect(busy == .oauth("temporarily_unavailable", description: nil))
        #expect(busy.friendlyDescription != nil)
        let broken = CoreAccountMapping.error(
            Self.failure("account.sign_in_refused", message: "the sign-in was refused: server_error"), during: .signIn
        )
        #expect(broken.friendlyDescription != nil)
    }

    @Test("A refusal the core passes on by its server code keeps that code, which the device page words")
    func serverCodesPassThrough() {
        let error = CoreAccountMapping.error(Self.failure("account.refused", server: "offline_file_active"), during: .other)
        #expect(error.deviceRemovalDescription == AccountError.server(status: 409, code: "offline_file_active").deviceRemovalDescription)
        #expect(Self.mapped("account.unreachable") == .network(""))
        #expect(Self.mapped("account.signed_out") == .signedOut)
    }

    @Test("An offline file the core refuses says why, by the reason the core gave")
    func offlineFileReasons() {
        let other = CoreAccountMapping.error(
            Self.failure("account.entitlement", message: "the entitlement was issued to another machine"), during: .offlineFile
        )
        let expired = CoreAccountMapping.error(
            Self.failure("account.entitlement", message: "the entitlement expired at 2026-11-01"), during: .offlineFile
        )
        #expect(other == .offlineFileRejected(.otherMachine))
        #expect(expired == .offlineFileRejected(.expired))
        #expect(Self.mapped("account.offline_file_too_large", .offlineFile) == .offlineFileRejected(.unreadable))
        #expect(Self.mapped("account.other_account", .offlineFile) == .offlineFileRejected(.otherAccount))
    }

    @Test("The core's status maps to the app's snapshot, an offline file and the device limit's holders included")
    func snapshot() {
        let holder = DeviceInfo(
            id: "dev_1", platform: "linux", name: "Workstation", appVersion: "1.0", osVersion: "Fedora 43",
            lastSeenAtSecs: 1_800_000_000, licensedAtSecs: 1_790_000_000, offlineUntilSecs: nil, isThisMachine: false
        )
        let status = AccountStatusInfo(
            state: .signedIn, accountId: "acct_1", email: "ada@example.com", name: "Ada", features: ["icloud_sync"],
            licenses: [], entitlementExpiresAtSecs: 1_800_000_000, offlineFile: true,
            problem: .deviceLimitReached(devices: [holder]), remembered: true
        )

        let snapshot = CoreAccountMapping.snapshot(status)

        #expect(snapshot.state == .signedIn)
        #expect(snapshot.accountID == "acct_1")
        #expect(snapshot.features == ["icloud_sync"])
        #expect(snapshot.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(snapshot.isOfflineFile)
        guard case .deviceLimitReached(let holders) = snapshot.problem else {
            Issue.record("Expected the device limit")
            return
        }
        #expect(holders.map(\.name) == ["Workstation"])
        #expect(holders.first?.holdsLicense == true)
        #expect(holders.first?.isThisMac == false)
    }

    @Test("A company server and its license read as the core verified them")
    func serverAndLicense() throws {
        let server = try #require(CoreAccountMapping.server(ServerInfo(
            apiOrigin: "https://tablepro.example.com", accountOrigin: nil, host: "tablepro.example.com",
            isProduction: false, isManaged: true, othersAllowed: false
        )))
        #expect(server.apiBaseURL.absoluteString == "https://tablepro.example.com/v2")
        #expect(server.accountOrigin == server.apiOrigin)
        #expect(server.isManaged && !server.othersAllowed)

        let license = CoreAccountMapping.license(ServerLicenseInfo(
            id: "lic_1", licenseType: "trial", seats: 10, features: ["team_library"], expiresAtSecs: 1_800_000_000,
            graceEndsAtSecs: 1_802_592_000, state: .grace
        ))
        #expect(license == AccountServerLicense(
            seats: 10, isTrial: true, expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            graceEndsAt: Date(timeIntervalSince1970: 1_802_592_000), state: .grace
        ))
    }

    @Test("A Debug run's development stack reads as tablepro.app, so its shares and plans show")
    func developmentStackIsTableProApp() throws {
        let info = ServerInfo(
            apiOrigin: "http://api.localhost:5284", accountOrigin: "http://account.localhost:5284", host: "api.localhost",
            isProduction: false, isManaged: false, othersAllowed: false
        )
        #expect(try #require(CoreAccountMapping.server(info, isDevelopmentStack: true)).isProduction)
        #expect(try #require(CoreAccountMapping.server(info)).isProduction == false)
    }

    @Test("The core's sign-out causes reach the app as its own")
    func causes() {
        #expect(CoreAccountMapping.cause(.requested) == .user)
        #expect(CoreAccountMapping.cause(.refused) == .refreshRefused)
        #expect(CoreAccountMapping.cause(.deviceRevoked) == .deviceRevoked)
        #expect(CoreAccountMapping.cause(.serverChanged) == .serverChanged)
    }
}

struct KeychainHostSecretsTests {
    @Test("The core's tablepro.app item is the Keychain item an earlier build left, so an update stays signed in")
    func productionItemIsTheEarlierOne() throws {
        let keychain = InMemoryKeychain()
        keychain.writeString("refresh-from-an-earlier-build", forKey: "com.TablePro.account.refreshToken")
        let secrets = KeychainHostSecrets(keychain: AccountKeychain(keychain: keychain))

        #expect(try secrets.loadItem(item: .accountRefreshToken) == "refresh-from-an-earlier-build")
    }

    @Test("A company server's token goes to its own item and never over tablepro.app's")
    func companyServerItem() throws {
        let keychain = InMemoryKeychain()
        let secrets = KeychainHostSecrets(keychain: AccountKeychain(keychain: keychain))
        try secrets.storeItem(item: .accountRefreshToken, secret: "production")

        try secrets.storeItem(item: .accountRefreshTokenFor(signInKey: "0123456789abcdef"), secret: "company")
        try secrets.deleteItem(item: .accountRefreshTokenFor(signInKey: "0123456789abcdef"))

        #expect(try secrets.loadItem(item: .accountRefreshToken) == "production")
        #expect(try secrets.loadItem(item: .accountRefreshTokenFor(signInKey: "0123456789abcdef")) == nil)
    }

    @Test("Secrets the Mac still keeps in Swift are not the core's to read")
    func otherSecretsAreRefused() {
        let secrets = KeychainHostSecrets(keychain: AccountKeychain(keychain: InMemoryKeychain()))
        #expect(throws: HostSecretError.self) { try secrets.loadItem(item: .anthropicKey) }
        #expect(throws: HostSecretError.self) { try secrets.load(connectionId: "c", kind: .databasePassword) }
    }
}
