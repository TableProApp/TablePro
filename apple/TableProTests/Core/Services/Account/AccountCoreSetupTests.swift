//
//  AccountCoreSetupTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct AccountCoreSetupTests {
    private struct Policy: ManagedPolicyReading {
        var url: String?
        var allowOthers: Bool?

        func string(_ policy: ManagedPolicy) -> String? { policy == .accountServerURL ? url : nil }
        func bool(_ policy: ManagedPolicy) -> Bool? { policy == .allowOtherAccountServers ? allowOthers : nil }
    }

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
            supportDirectory: Self.support, machineID: "mid", policy: Policy(), environment: [:], isDebugBuild: false
        )
        #expect(setup.legacyEntitlementFile.path == "/Users/ada/Library/Application Support/TablePro/Account/entitlement.jwt")
        #expect(setup.accountFile.path == "/Users/ada/Library/Application Support/TablePro/Account/account.json")
        #expect(setup.machineID == "mid")
    }

    @Test("The managed values go to the core as the profile set them, and nothing when it set none")
    func managedValues() {
        let managed = AccountCoreSetup.make(
            supportDirectory: Self.support, machineID: "mid",
            policy: Policy(url: "https://tablepro.example.com", allowOthers: false), environment: [:], isDebugBuild: false
        )
        #expect(managed.managedServerURL == "https://tablepro.example.com")
        #expect(managed.allowOtherServers == false)

        let unmanaged = AccountCoreSetup.make(
            supportDirectory: Self.support, machineID: "mid", policy: Policy(), environment: [:], isDebugBuild: false
        )
        #expect(unmanaged.managedServerURL == nil)
        #expect(unmanaged.allowOtherServers == nil)
    }

    @Test("Only a Debug build names a development stack, and only when both of its addresses are set")
    func developmentStackIsDebugOnly() {
        let debug = AccountCoreSetup.make(
            supportDirectory: Self.support, machineID: "mid", policy: Policy(), environment: Self.stack, isDebugBuild: true
        )
        #expect(debug.developmentStack == .init(
            accountURL: "http://account.localhost:5284",
            apiURL: "http://api.localhost:5284",
            entitlementKeys: ["key-one", "key-two"],
            licenseKeys: ["license-one"]
        ))

        let release = AccountCoreSetup.make(
            supportDirectory: Self.support, machineID: "mid", policy: Policy(), environment: Self.stack, isDebugBuild: false
        )
        #expect(release.developmentStack == nil)

        var half = Self.stack
        half["TABLEPRO_API_URL"] = nil
        let partial = AccountCoreSetup.make(
            supportDirectory: Self.support, machineID: "mid", policy: Policy(), environment: half, isDebugBuild: true
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
