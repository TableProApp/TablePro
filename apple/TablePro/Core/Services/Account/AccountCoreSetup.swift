//
//  AccountCoreSetup.swift
//  TablePro
//

import Foundation

// What the app hands the core's account when it opens it: where the account lives, this Mac's ID and the raw
// managed values. The core resolves the server from them (core ADR 0044, App configuration).
internal struct AccountCoreSetup: Equatable, Sendable {
    // A local tablepro-cloud for a Debug run. The core takes them only from a build of it with debug assertions.
    struct DevelopmentStack: Equatable, Sendable {
        let accountURL: String
        let apiURL: String
        let entitlementKeys: [String]
        let licenseKeys: [String]
    }

    let accountFile: URL
    // What builds before the core kept; read once, when accountFile is missing, so the update stays signed in.
    let legacyEntitlementFile: URL
    let machineID: String
    let managedServerURL: String?
    let allowOtherServers: Bool?
    let developmentStack: DevelopmentStack?

    // The managed values as ManagedPolicyReader read them: only what a configuration profile forces.
    static func make(
        supportDirectory: URL,
        machineID: String,
        managedServerURL: String?,
        allowOtherServers: Bool?,
        environment: [String: String],
        isDebugBuild: Bool
    ) -> AccountCoreSetup {
        let folder = supportDirectory.appendingPathComponent("Account", isDirectory: true)
        return AccountCoreSetup(
            accountFile: folder.appendingPathComponent("account.json"),
            legacyEntitlementFile: folder.appendingPathComponent("entitlement.jwt"),
            machineID: machineID,
            managedServerURL: managedServerURL,
            allowOtherServers: allowOtherServers,
            developmentStack: isDebugBuild ? developmentStack(environment) : nil
        )
    }

    // A core built without debug assertions refuses these and the account does not open; build one that takes them
    // with CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS=true scripts/build-core.sh.
    static func developmentStack(_ environment: [String: String]) -> DevelopmentStack? {
        guard let account = environment["TABLEPRO_ACCOUNT_URL"], let api = environment["TABLEPRO_API_URL"] else {
            return nil
        }
        return DevelopmentStack(
            accountURL: account,
            apiURL: api,
            entitlementKeys: list(environment["TABLEPRO_ENTITLEMENT_KEYS"]),
            licenseKeys: list(environment["TABLEPRO_LICENSE_KEYS"])
        )
    }

    private static func list(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
