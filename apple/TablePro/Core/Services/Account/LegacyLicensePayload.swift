//
//  LegacyLicensePayload.swift
//  TablePro
//

import Foundation

// The signed payload the license server gave older builds, kept only to read it until migration.
internal struct LicensePayloadData: Codable, Equatable, Sendable {
    let billingCycle: String?
    let licenseKey: String
    let email: String
    let status: String
    let expiresAt: String?
    let issuedAt: String
    let tier: String
    let teamId: String?
    let role: String?
    let machineId: String?

    init(
        billingCycle: String?,
        licenseKey: String,
        email: String,
        status: String,
        expiresAt: String?,
        issuedAt: String,
        tier: String,
        teamId: String? = nil,
        role: String? = nil,
        machineId: String? = nil
    ) {
        self.billingCycle = billingCycle
        self.licenseKey = licenseKey
        self.email = email
        self.status = status
        self.expiresAt = expiresAt
        self.issuedAt = issuedAt
        self.tier = tier
        self.teamId = teamId
        self.role = role
        self.machineId = machineId
    }

    private enum CodingKeys: String, CodingKey {
        case billingCycle = "billing_cycle"
        case licenseKey = "license_key"
        case email
        case status
        case expiresAt = "expires_at"
        case issuedAt = "issued_at"
        case tier
        case teamId = "team_id"
        case role
        case machineId = "machine_id"
    }

    // The signature covers PHP's json_encode output, which writes nulls, except for the three keys
    // the server added later and omits unless they apply.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let billingCycle {
            try container.encode(billingCycle, forKey: .billingCycle)
        } else {
            try container.encodeNil(forKey: .billingCycle)
        }
        try container.encode(licenseKey, forKey: .licenseKey)
        try container.encode(email, forKey: .email)
        try container.encode(status, forKey: .status)
        if let expiresAt {
            try container.encode(expiresAt, forKey: .expiresAt)
        } else {
            try container.encodeNil(forKey: .expiresAt)
        }
        try container.encode(issuedAt, forKey: .issuedAt)
        try container.encode(tier, forKey: .tier)
        try container.encodeIfPresent(teamId, forKey: .teamId)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(machineId, forKey: .machineId)
    }
}

internal struct SignedLicensePayload: Codable, Equatable, Sendable {
    let data: LicensePayloadData
    let signature: String
}

// The envelope older builds wrote to UserDefaults; machineId is where it was cached, not a binding.
internal struct License: Codable, Equatable, Sendable {
    var signedPayload: SignedLicensePayload
    var cachedOnMachineId: String

    private enum CodingKeys: String, CodingKey {
        case signedPayload
        case cachedOnMachineId = "machineId"
    }
}

internal enum LicenseError: Error, Equatable {
    case signatureInvalid
}
