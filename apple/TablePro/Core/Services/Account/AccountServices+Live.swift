//
//  AccountServices+Live.swift
//  TablePro
//

import Foundation
import SystemConfiguration
import TableProCloudAPI

extension AccountServices {
    static func live() -> AccountServices {
        let environment = AppStorageEnvironment.shared
        let machine = MachineDescription.current()
        let session = URLSession(configuration: .ephemeral)
        return AccountServices(
            configuration: .current(),
            machine: machine,
            transport: UnavailableTransport(),
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

// swift-openapi-urlsession 1.4.0 was under two weeks old when the client landed and waits on the
// owner's pick, so until a transport is chosen every /v2 call fails the way an offline Mac's does.
internal struct UnavailableTransport: ClientTransport {
    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        throw URLError(.notConnectedToInternet)
    }
}
