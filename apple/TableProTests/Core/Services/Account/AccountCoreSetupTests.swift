//
//  AccountCoreSetupTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct AccountCoreSetupTests {
    private static let support = URL(fileURLWithPath: "/Users/ada/Library/Application Support/TablePro", isDirectory: true)
    private static let stack = [
        "TABLEPRO_ACCOUNT_URL": "http://account.localhost:5284",
        "TABLEPRO_API_URL": "http://api.localhost:5284",
        "TABLEPRO_ENTITLEMENT_KEYS": " key-one, key-two ,",
        "TABLEPRO_LICENSE_KEYS": "license-one"
    ]

    @Test("The core takes over the entitlement file earlier builds kept, beside its own account file")
    func filesSitWhereEarlierBuildsKeptThem() {
        let setup = AccountCoreSetup.make(
            supportDirectory: Self.support, machineID: "mid", policy: ManagedPolicySnapshot(),
            environment: [:], isDebugBuild: false
        )
        #expect(setup.legacyEntitlementFile.path == "/Users/ada/Library/Application Support/TablePro/Account/entitlement.jwt")
        #expect(setup.accountFile.path == "/Users/ada/Library/Application Support/TablePro/Account/account.json")
        #expect(setup.machineID == "mid")
    }

    @Test("The managed values go to the core as the profile set them, and nothing when it set none")
    func managedValues() {
        let values = ManagedPolicySnapshot(
            accountServerURL: "https://tablepro.example.com",
            allowOtherAccountServers: false,
            personalSyncProvider: ["icloud"],
            usageDataAllowed: false
        )
        let managed = AccountCoreSetup.make(
            supportDirectory: Self.support, machineID: "mid", policy: values, environment: [:], isDebugBuild: false
        )
        #expect(managed.policy == values)

        let unmanaged = AccountCoreSetup.make(
            supportDirectory: Self.support, machineID: "mid", policy: ManagedPolicySnapshot(),
            environment: [:], isDebugBuild: false
        )
        #expect(unmanaged.policy == ManagedPolicySnapshot())
    }

    @Test("Only a Debug build names a development stack, and only when both of its addresses are set")
    func developmentStackIsDebugOnly() {
        let debug = AccountCoreSetup.make(
            supportDirectory: Self.support, machineID: "mid", policy: ManagedPolicySnapshot(),
            environment: Self.stack, isDebugBuild: true
        )
        #expect(debug.developmentStack == .init(
            accountURL: "http://account.localhost:5284",
            apiURL: "http://api.localhost:5284",
            entitlementKeys: ["key-one", "key-two"],
            licenseKeys: ["license-one"]
        ))
        #expect(debug.developmentStack?.apiBase == "http://api.localhost:5284/v2")

        let release = AccountCoreSetup.make(
            supportDirectory: Self.support, machineID: "mid", policy: ManagedPolicySnapshot(),
            environment: Self.stack, isDebugBuild: false
        )
        #expect(release.developmentStack == nil)

        var half = Self.stack
        half["TABLEPRO_API_URL"] = nil
        let partial = AccountCoreSetup.make(
            supportDirectory: Self.support, machineID: "mid", policy: ManagedPolicySnapshot(),
            environment: half, isDebugBuild: true
        )
        #expect(partial.developmentStack == nil)
    }
}

struct AccountRefreshTokenItemTests {
    @Test("tablepro.app's refresh token stays in the item earlier builds wrote, so an update stays signed in")
    func productionKeepsTheItem() {
        #expect(AccountRefreshTokenItem.key(signInKey: nil) == "com.TablePro.account.refreshToken")
        #expect(AccountRefreshTokenItem.key(signInKey: "") == "com.TablePro.account.refreshToken")
    }

    @Test("Each company server's refresh token has an item of its own")
    func companyServersGetTheirOwn() {
        #expect(AccountRefreshTokenItem.key(signInKey: "a1b2") == "com.TablePro.account.refreshToken.a1b2")
        #expect(AccountRefreshTokenItem.key(signInKey: "a1b2") != AccountRefreshTokenItem.key(signInKey: "c3d4"))
    }
}

struct AccountKeychainTests {
    @Test("The core reads the refresh token an earlier build stored, so the update stays signed in")
    func readsTheEarlierItem() throws {
        let keychain = InMemoryKeychain()
        keychain.writeString("refresh-from-an-earlier-build", forKey: "com.TablePro.account.refreshToken")

        #expect(try AccountKeychain(keychain: keychain).refreshToken(signInKey: nil) == "refresh-from-an-earlier-build")
    }

    @Test("A company server's token is stored, read and deleted apart from tablepro.app's")
    func serversKeepTheirOwnTokens() throws {
        let keychain = InMemoryKeychain()
        let account = AccountKeychain(keychain: keychain)
        try account.storeRefreshToken("production", signInKey: nil)
        try account.storeRefreshToken("company", signInKey: "a1b2")

        account.deleteRefreshToken(signInKey: "a1b2")

        #expect(try account.refreshToken(signInKey: nil) == "production")
        #expect(try account.refreshToken(signInKey: "a1b2") == nil)
    }
}
