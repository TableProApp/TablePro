//
//  AccountDevelopmentStack.swift
//  TablePro
//

import Foundation

// A local tablepro-cloud for a Debug run, named by the run's environment. The core takes it only from a build of it
// with debug assertions; build one that does with CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS=true scripts/build-core.sh.
// Both addresses make it the one server the app signs in to, as tablepro.app; license keys alone leave the server to the
// person and the policy, so a company server's discovery and license check run against a test license.
nonisolated internal struct AccountDevelopmentStack: Equatable, Sendable {
    let accountURL: String?
    let apiURL: String?
    // The core takes these only with both addresses.
    let entitlementKeys: [String]
    let licenseKeys: [String]

    // TABLEPRO_API_URL is the API's origin, as for tablepro.app; the core takes the /v2 base.
    var apiBase: String? {
        apiURL.map { ($0.hasSuffix("/") ? String($0.dropLast()) : $0) + "/v2" }
    }

    static func read(_ environment: [String: String]) -> AccountDevelopmentStack? {
        let licenseKeys = list(environment["TABLEPRO_LICENSE_KEYS"])
        guard let account = environment["TABLEPRO_ACCOUNT_URL"], let api = environment["TABLEPRO_API_URL"] else {
            guard !licenseKeys.isEmpty else { return nil }
            return AccountDevelopmentStack(accountURL: nil, apiURL: nil, entitlementKeys: [], licenseKeys: licenseKeys)
        }
        return AccountDevelopmentStack(
            accountURL: account,
            apiURL: api,
            entitlementKeys: list(environment["TABLEPRO_ENTITLEMENT_KEYS"]),
            licenseKeys: licenseKeys
        )
    }

    private static func list(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
