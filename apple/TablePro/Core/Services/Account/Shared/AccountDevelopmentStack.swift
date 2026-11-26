//
//  AccountDevelopmentStack.swift
//  TablePro
//

import Foundation

// A local tablepro-cloud for a Debug run, named by the run's environment. The core takes it only from a build of it
// with debug assertions; build one that does with CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS=true scripts/build-core.sh.
nonisolated internal struct AccountDevelopmentStack: Equatable, Sendable {
    let accountURL: String
    let apiURL: String
    let entitlementKeys: [String]
    let licenseKeys: [String]

    // TABLEPRO_API_URL is the API's origin, as for tablepro.app; the core takes the /v2 base.
    var apiBase: String {
        (apiURL.hasSuffix("/") ? String(apiURL.dropLast()) : apiURL) + "/v2"
    }

    static func read(_ environment: [String: String]) -> AccountDevelopmentStack? {
        guard let account = environment["TABLEPRO_ACCOUNT_URL"], let api = environment["TABLEPRO_API_URL"] else {
            return nil
        }
        return AccountDevelopmentStack(
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
