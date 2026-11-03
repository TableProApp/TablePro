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
        let session = liveSession()
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

    // A token request's body carries the refresh token or a license key, and URLSession resends a 307's body to
    // wherever the redirect points.
    nonisolated static func liveSession() -> URLSession {
        URLSession(configuration: .ephemeral, delegate: SameOriginRedirects.shared, delegateQueue: nil)
    }
}
