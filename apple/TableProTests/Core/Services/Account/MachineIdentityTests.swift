//
//  MachineIdentityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct MachineIdentityTests {
    @Test("The machine ID is the SHA-256 of the hardware UUID, as the license system registered it")
    func machineIDMatchesTheLicenseSystem() throws {
        let defaults = try EphemeralDefaults()
        let id = MachineIdentity.compute(hardwareUUID: "00000000-0000-0000-0000-000000000000", defaults: defaults.defaults)
        #expect(id == "12b9377cbe7e5c94e8a70d9d23929523d14afa954793130f8a3959c7b849aca8")
        #expect(id.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
    }

    @Test("Without a hardware UUID the fallback ID is made once and kept")
    func fallbackIsStable() throws {
        let defaults = try EphemeralDefaults()
        let first = MachineIdentity.compute(hardwareUUID: nil, defaults: defaults.defaults)
        let second = MachineIdentity.compute(hardwareUUID: nil, defaults: defaults.defaults)
        #expect(first == second)
        #expect(defaults.defaults.string(forKey: MachineIdentity.fallbackKey) != nil)
    }

    @Test("The OS version reads like 26.1, with the patch only when there is one")
    func osVersion() {
        #expect(MachineDescription.osVersion(OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)) == "26.1")
        #expect(MachineDescription.osVersion(OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 2)) == "26.1.2")
    }

    @Test("Release points at production, and a Debug run can point at a local stack")
    func configuration() throws {
        let production = AccountConfiguration.production
        #expect(production.accountURL.absoluteString == "https://account.tablepro.app")
        #expect(production.apiServerURL.absoluteString == "https://api.tablepro.app/v2")
        #expect(production.tokenEndpoint.absoluteString == "https://account.tablepro.app/oauth/token")
        #expect(production.revocationEndpoint.absoluteString == "https://account.tablepro.app/oauth/revoke")

        let local = production.overridden(by: [
            "TABLEPRO_ACCOUNT_URL": "http://account.localhost:5284",
            "TABLEPRO_API_URL": "http://api.localhost:5284",
            "TABLEPRO_ENTITLEMENT_KEYS": "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
        ])
        #expect(local.tokenEndpoint.absoluteString == "http://account.localhost:5284/oauth/token")
        #expect(local.apiServerURL.absoluteString == "http://api.localhost:5284/v2")
        let keyIDs = local.entitlementKeys.map { EntitlementVerifier.keyID(of: $0) }
        #expect(keyIDs.contains("kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k"))
    }
}
