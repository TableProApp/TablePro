//
//  LegacyLicenseStore.swift
//  TablePro
//

import Foundation
import os

// What a license activated by an older build still grants until it is exchanged for an account.
internal struct LegacyEntitlement: Equatable, Sendable {
    // The older build paused paid features 30 days after the server last signed the payload.
    static let gracePeriod: TimeInterval = 30 * 24 * 60 * 60

    // The payload names a tier, not features; this table only outlives the payload until migration.
    static let starterFeatures: Set<String> = [
        "icloud_sync", "encrypted_export", "env_var_references", "linked_folders",
        "query_insights", "result_charts", "compare_sync", "data_rewind"
    ]
    static let teamFeatures: Set<String> = starterFeatures.union(["team_catalog", "team_library"])

    let features: Set<String>
    let issuedAt: Date?
    let expiresAt: Date?

    init?(payload: LicensePayloadData) {
        guard payload.status == "active" else { return nil }
        let dates = RFC3339DateTranscoder()
        self.issuedAt = try? dates.decode(payload.issuedAt)
        self.expiresAt = payload.expiresAt.flatMap { try? dates.decode($0) }
        switch payload.tier.trimmingCharacters(in: .whitespaces).lowercased() {
        case "", "starter":
            features = Self.starterFeatures
        default:
            features = Self.teamFeatures
        }
    }

    // An issue date the older build could not read never counted against the license either.
    func isValid(at now: Date) -> Bool {
        if let expiresAt, expiresAt <= now { return false }
        guard let issuedAt else { return true }
        return now.timeIntervalSince(issuedAt) <= Self.gracePeriod
    }
}

// The license key and signed payload an older build stored, read until the key exchange retires them.
internal struct LegacyLicenseStore: Sendable {
    static let keychainKey = "com.TablePro.license.key"
    static let payloadKey = "com.TablePro.license.payload"

    private static let logger = Logger(subsystem: "com.TablePro", category: "LegacyLicenseStore")

    let keychain: any KeychainStoring
    let defaults: UserDefaults
    let machineID: String
    let verify: @Sendable (SignedLicensePayload) throws -> LicensePayloadData

    // The payload carries the key too, for a Mac whose Keychain copy another Mac's migration deleted.
    func licenseKey() -> String? {
        if case .found(let key) = keychain.readStringResult(forKey: Self.keychainKey) {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return verifiedPayload()?.licenseKey
    }

    func entitlement() -> LegacyEntitlement? {
        verifiedPayload().flatMap(LegacyEntitlement.init(payload:))
    }

    func clear() {
        keychain.delete(forKey: Self.keychainKey)
        defaults.removeObject(forKey: Self.payloadKey)
    }

    private func verifiedPayload() -> LicensePayloadData? {
        guard let data = defaults.data(forKey: Self.payloadKey),
              let cached = try? JSONDecoder().decode(License.self, from: data),
              cached.cachedOnMachineId == machineID,
              let payload = try? verify(cached.signedPayload)
        else { return nil }
        if let bound = payload.machineId, bound != machineID {
            Self.logger.notice("The stored license payload was signed for another Mac")
            return nil
        }
        return payload
    }
}
