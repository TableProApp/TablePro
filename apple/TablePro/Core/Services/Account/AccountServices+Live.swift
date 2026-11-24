//
//  AccountServices+Live.swift
//  TablePro
//

import Foundation
import TableProHTTP

extension AccountServices {
    static func live() -> AccountServices {
        let environment = AppStorageEnvironment.shared
        let machine = MachineDescription.current()
        let setup = AccountCoreSetup.make(
            supportDirectory: environment.supportDirectory,
            machineID: machine.machineID,
            managedServerURL: ManagedPolicyReader.shared.string(.accountServerURL),
            allowOtherServers: ManagedPolicyReader.shared.bool(.allowOtherAccountServers),
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: isDebugBuild
        )
        let backend = CoreAccountBackend(
            setup: setup,
            machine: machine,
            keychain: AccountKeychain(keychain: environment.deviceOnlyKeychain)
        )
        let services = AccountServices(
            backend: backend,
            transport: AccountAPI.transport(session: liveSession()),
            storedKey: StoredLicenseKey(
                keychain: environment.keychain,
                defaults: environment.defaults,
                machineID: machine.machineID
            ),
            access: .shared,
            sharedLinkServer: setup.developmentStack.flatMap { URL(string: $0.apiURL)?.appendingPathComponent("v2") }
                ?? AccountServer.production.apiBaseURL
        )
        backend.setListener(services)
        return services
    }

    // A request carries the bearer, and URLSession resends a 307's headers and body to wherever the redirect points.
    nonisolated static func liveSession() -> URLSession {
        URLSession(configuration: .ephemeral, delegate: SameOriginRedirects.shared, delegateQueue: nil)
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
