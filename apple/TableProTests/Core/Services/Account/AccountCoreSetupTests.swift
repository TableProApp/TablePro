//
//  AccountCoreSetupTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
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
            supportDirectory: Self.support, machineID: "mid", managedServerURL: nil, allowOtherServers: nil,
            environment: [:], isDebugBuild: false
        )
        #expect(setup.legacyEntitlementFile.path == "/Users/ada/Library/Application Support/TablePro/Account/entitlement.jwt")
        #expect(setup.accountFile.path == "/Users/ada/Library/Application Support/TablePro/Account/account.json")
        #expect(setup.machineID == "mid")
    }

    @Test("The managed values go to the core as the profile set them, and nothing when it set none")
    func managedValues() {
        let managed = AccountCoreSetup.make(
            supportDirectory: Self.support, machineID: "mid",
            managedServerURL: "https://tablepro.example.com", allowOtherServers: false, environment: [:], isDebugBuild: false
        )
        #expect(managed.managedServerURL == "https://tablepro.example.com")
        #expect(managed.allowOtherServers == false)

        let unmanaged = AccountCoreSetup.make(
            supportDirectory: Self.support, machineID: "mid", managedServerURL: nil, allowOtherServers: nil,
            environment: [:], isDebugBuild: false
        )
        #expect(unmanaged.managedServerURL == nil)
        #expect(unmanaged.allowOtherServers == nil)
    }

    @Test("Only a Debug build names a development stack, and only when both of its addresses are set")
    func developmentStackIsDebugOnly() {
        let debug = AccountCoreSetup.make(
            supportDirectory: Self.support, machineID: "mid", managedServerURL: nil, allowOtherServers: nil,
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
            supportDirectory: Self.support, machineID: "mid", managedServerURL: nil, allowOtherServers: nil,
            environment: Self.stack, isDebugBuild: false
        )
        #expect(release.developmentStack == nil)

        var half = Self.stack
        half["TABLEPRO_API_URL"] = nil
        let partial = AccountCoreSetup.make(
            supportDirectory: Self.support, machineID: "mid", managedServerURL: nil, allowOtherServers: nil,
            environment: half, isDebugBuild: true
        )
        #expect(partial.developmentStack == nil)
    }
}

struct AccountCoreSetupConfigTests {
    @Test("The core gets the Mac's client, its machine ID, the profile's values and the entitlement file from before")
    func configIsTheMacs() {
        let setup = AccountCoreSetup.make(
            supportDirectory: URL(fileURLWithPath: "/Users/ada/Library/Application Support/TablePro", isDirectory: true),
            machineID: "mid", managedServerURL: "https://tablepro.example.com", allowOtherServers: false,
            environment: [:], isDebugBuild: false
        )
        let machine = MachineDescription(machineID: "mid", name: "Ada's Mac", appVersion: "0.90.0", osVersion: "26.1")

        let config = setup.accountConfig(machine: machine)

        #expect(config.client == .macos)
        #expect(config.machineId == "mid")
        #expect(config.deviceName == "Ada's Mac")
        #expect(config.managedServerUrl == "https://tablepro.example.com")
        #expect(config.allowOtherServers == false)
        #expect(config.legacyEntitlementFile == setup.legacyEntitlementFile.path)
        #expect(config.accountUrl == nil && config.apiUrl == nil && config.licenseKeys.isEmpty)
    }

    @Test("A development stack's addresses and keys reach the core with the /v2 base")
    func developmentStackReachesTheCore() {
        let setup = AccountCoreSetup.make(
            supportDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true), machineID: "mid",
            managedServerURL: nil, allowOtherServers: nil,
            environment: ["TABLEPRO_ACCOUNT_URL": "http://account.localhost:5284", "TABLEPRO_API_URL": "http://api.localhost:5284/"],
            isDebugBuild: true
        )
        let machine = MachineDescription(machineID: "mid", name: "Mac", appVersion: "0.90.0", osVersion: "26.1")

        let config = setup.accountConfig(machine: machine)

        #expect(config.accountUrl == "http://account.localhost:5284")
        #expect(config.apiUrl == "http://api.localhost:5284/v2")
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
