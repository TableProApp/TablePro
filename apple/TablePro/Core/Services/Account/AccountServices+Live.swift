//
//  AccountServices+Live.swift
//  TablePro
//

import Foundation

extension AccountServices {
    static func live() -> AccountServices {
        let environment = AppStorageEnvironment.shared
        let machine = MachineDescription.current()
        let session = URLSession(configuration: .ephemeral)
        return AccountServices(
            configuration: .current(),
            machine: machine,
            transport: AccountAPI.transport(session: session),
            send: { request in try await session.data(for: request) },
            keychain: environment.deviceOnlyKeychain,
            entitlementFile: environment.supportDirectory
                .appendingPathComponent("Account", isDirectory: true)
                .appendingPathComponent("entitlement.jwt"),
            legacy: LegacyLicenseStore(
                keychain: environment.keychain,
                defaults: environment.defaults,
                machineID: machine.machineID,
                verify: { try LicenseSignatureVerifier.shared.verify(payload: $0) }
            ),
            access: .shared
        )
    }
}
