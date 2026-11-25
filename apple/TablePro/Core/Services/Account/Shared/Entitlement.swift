//
//  Entitlement.swift
//  TablePro
//

import Foundation

nonisolated internal struct EntitlementLicense: Equatable, Sendable {
    struct Team: Equatable, Sendable {
        let id: String
        let name: String
    }

    let id: String
    let plan: String
    let cycle: String
    let source: String
    let status: String
    // An active subscription's period end; nil for every other license.
    let renewsAt: Date?
    let endsAt: Date?
    let team: Team?
}

// The entitlement the core verified, for display. Only the core's gate decides what it unlocks.
nonisolated internal struct Entitlement: Equatable, Sendable {
    let accountID: String
    let features: Set<String>
    let licenses: [EntitlementLicense]
    let email: String
    let name: String?
    let expiresAt: Date
    let isOffline: Bool

    init(
        accountID: String,
        features: Set<String>,
        licenses: [EntitlementLicense],
        email: String,
        name: String?,
        expiresAt: Date,
        isOffline: Bool
    ) {
        self.accountID = accountID
        self.features = features
        self.licenses = licenses
        self.email = email
        self.name = name
        self.expiresAt = expiresAt
        self.isOffline = isOffline
    }

    init?(_ snapshot: AccountSnapshot) {
        guard snapshot.state != .signedOut, let accountID = snapshot.accountID, let expiresAt = snapshot.expiresAt else {
            return nil
        }
        self.init(
            accountID: accountID,
            features: snapshot.features,
            licenses: snapshot.licenses,
            email: snapshot.email ?? "",
            name: snapshot.name,
            expiresAt: expiresAt,
            isOffline: snapshot.isOfflineFile || snapshot.state == .offline
        )
    }

    func isValid(at now: Date) -> Bool {
        now < expiresAt
    }
}
