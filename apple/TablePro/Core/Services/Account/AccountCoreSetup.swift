//
//  AccountCoreSetup.swift
//  TablePro
//

import Foundation
import TableProFFI

// What the app hands the core's account when it opens it: where the account lives, this Mac's ID and the raw
// managed values. The core resolves the server from them (core ADR 0044, App configuration).
internal struct AccountCoreSetup: Equatable, Sendable {
    let accountFile: URL
    // What builds before the core kept; read once, when accountFile is missing, so the update stays signed in.
    let legacyEntitlementFile: URL
    let machineID: String
    let managedServerURL: String?
    let allowOtherServers: Bool?
    let developmentStack: AccountDevelopmentStack?

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
            developmentStack: isDebugBuild ? AccountDevelopmentStack.read(environment) : nil
        )
    }

    func accountConfig(machine: MachineDescription) -> AccountConfig {
        AccountConfig(
            accountUrl: developmentStack?.accountURL,
            apiUrl: developmentStack?.apiBase,
            entitlementKeys: developmentStack?.entitlementKeys ?? [],
            deviceName: machine.name,
            appVersion: machine.appVersion,
            osVersion: machine.osVersion,
            accountFile: accountFile.path,
            callbackFinished: "",
            callbackUnknown: "",
            machineGuid: nil,
            client: .macos,
            machineId: machineID,
            managedServerUrl: managedServerURL,
            allowOtherServers: allowOtherServers,
            legacyEntitlementFile: legacyEntitlementFile.path,
            licenseKeys: developmentStack?.licenseKeys ?? []
        )
    }
}
