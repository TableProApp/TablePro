//
//  License.swift
//  TablePro
//
//  License model, signed payload types, and error definitions
//

import Foundation

// MARK: - License Status

/// Represents the current license state in the app
enum LicenseStatus: String, Codable {
    case unlicensed
    case active
    case expired
    case suspended
    case deactivated
    case validationFailed

    var displayName: String {
        switch self {
        case .unlicensed: return String(localized: "Unlicensed")
        case .active: return String(localized: "Active")
        case .expired: return String(localized: "Expired")
        case .suspended: return String(localized: "Suspended")
        case .deactivated: return String(localized: "Deactivated")
        case .validationFailed: return String(localized: "Validation Failed")
        }
    }

    var isValid: Bool {
        self == .active
    }
}

// MARK: - Server Response Types

/// The `data` portion of the signed license payload from the server
struct LicensePayloadData: Codable, Equatable {
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

    /// Custom encode to explicitly write null for nil optionals.
    /// The auto-synthesized Codable uses encodeIfPresent which omits nil keys,
    /// but PHP's json_encode includes null values — the signed JSON must match exactly.
    ///
    /// `team_id`, `role` and `machine_id` are the exception: the server omits them unless they
    /// apply, so they use encodeIfPresent (dropped when nil). This keeps a payload signed before
    /// those keys existed verifying byte-for-byte against a build that knows about them.
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

/// Signed license payload returned by the server (data + RSA signature)
struct SignedLicensePayload: Codable, Equatable {
    let data: LicensePayloadData
    let signature: String
}

// MARK: - API Request/Response Types

/// Request body for license activation
struct LicenseActivationRequest: Codable {
    let licenseKey: String
    let machineId: String
    let machineName: String
    let appVersion: String
    let osVersion: String

    private enum CodingKeys: String, CodingKey {
        case licenseKey = "license_key"
        case machineId = "machine_id"
        case machineName = "machine_name"
        case appVersion = "app_version"
        case osVersion = "os_version"
    }
}

/// Request body for accepting a team invitation (activation via invite code)
struct LicenseAcceptInviteRequest: Codable {
    let token: String
    let machineId: String
    let machineName: String
    let appVersion: String
    let osVersion: String

    private enum CodingKeys: String, CodingKey {
        case token
        case machineId = "machine_id"
        case machineName = "machine_name"
        case appVersion = "app_version"
        case osVersion = "os_version"
    }
}

/// Request body for license validation
struct LicenseValidationRequest: Codable {
    let licenseKey: String
    let machineId: String
    let machineName: String
    let appVersion: String
    let osVersion: String

    private enum CodingKeys: String, CodingKey {
        case licenseKey = "license_key"
        case machineId = "machine_id"
        case machineName = "machine_name"
        case appVersion = "app_version"
        case osVersion = "os_version"
    }
}

/// Request body for license deactivation
struct LicenseDeactivationRequest: Codable {
    let licenseKey: String
    let machineId: String

    private enum CodingKeys: String, CodingKey {
        case licenseKey = "license_key"
        case machineId = "machine_id"
    }
}

/// Response from the deactivation endpoint
struct DeactivateResponse: Codable {
    let message: String
}

/// Wrapper for API error responses
struct LicenseAPIErrorResponse: Codable {
    let message: String
}

/// Information about a single license activation (machine)
internal struct LicenseActivationInfo: Codable, Identifiable {
    var id: String { machineId }
    let machineId: String
    let machineName: String
    let appVersion: String
    let osVersion: String
    let lastValidatedAt: String?
    let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case machineId = "machine_id"
        case machineName = "machine_name"
        case appVersion = "app_version"
        case osVersion = "os_version"
        case lastValidatedAt = "last_validated_at"
        case createdAt = "created_at"
    }
}

/// Response from the list activations endpoint
internal struct ListActivationsResponse: Codable {
    let activations: [LicenseActivationInfo]
    let maxActivations: Int

    private enum CodingKeys: String, CodingKey {
        case activations
        case maxActivations = "max_activations"
    }
}

// MARK: - Cached License

/// Cache envelope around the server's signed payload.
///
/// Every field that drives gating is computed from `signedPayload.data`, so a forged value has
/// nowhere to live: the RSA signature covers all of it. `cachedOnMachineId` is the one locally
/// written field and it is not a security control, only the tripwire that drops a cache restored
/// from another Mac's backup. The binding that holds against tampering is `boundMachineId`,
/// which the server signs.
struct License: Codable, Equatable {
    var signedPayload: SignedLicensePayload
    var cachedOnMachineId: String

    private enum CodingKeys: String, CodingKey {
        case signedPayload
        case cachedOnMachineId = "machineId"
    }

    private var payload: LicensePayloadData { signedPayload.data }

    var key: String { payload.licenseKey }

    var email: String { payload.email }

    var tier: String { payload.tier }

    var billingCycle: String? { payload.billingCycle }

    var boundMachineId: String? { payload.machineId }

    var status: LicenseStatus {
        switch payload.status {
        case "active": .active
        case "expired": .expired
        case "suspended": .suspended
        default: .validationFailed
        }
    }

    var expiresAt: Date? {
        payload.expiresAt.flatMap { Self.iso8601Formatter.date(from: $0) }
    }

    /// When the server signed this payload, which is when it last confirmed the license.
    var issuedAt: Date? {
        Self.iso8601Formatter.date(from: payload.issuedAt)
    }

    /// Whether the license has expired based on expiration date
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < Date()
    }

    /// Days until the license expires (nil for lifetime licenses)
    var daysUntilExpiry: Int? {
        guard let expiresAt else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day
    }

    /// Days since the server last confirmed this license, or nil when the payload does not say.
    /// A clock behind the server reads as zero rather than as a license from the future.
    var daysSinceLastValidation: Int? {
        guard let issuedAt else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: issuedAt, to: Date()).day ?? 0)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

// MARK: - License Error

/// Errors that can occur during license operations
enum LicenseError: LocalizedError {
    case invalidKey
    case signatureInvalid
    case machineMismatch
    case publicKeyNotFound
    case publicKeyInvalid
    case activationLimitReached
    case licenseExpired
    case licenseSuspended
    case notActivated
    case networkError(Error)
    case serverError(Int, String)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return String(localized: "The license key is invalid.")
        case .signatureInvalid:
            return String(localized: "License signature verification failed.")
        case .machineMismatch:
            return String(localized: "This license was issued for a different Mac.")
        case .publicKeyNotFound:
            return String(localized: "License public key not found in app bundle.")
        case .publicKeyInvalid:
            return String(localized: "License public key is invalid.")
        case .activationLimitReached:
            return String(localized: "Maximum number of activations reached.")
        case .licenseExpired:
            return String(localized: "The license has expired.")
        case .licenseSuspended:
            return String(localized: "The license has been suspended.")
        case .notActivated:
            return String(localized: "This machine is not activated.")
        case .networkError(let error):
            return String(format: String(localized: "Network error: %@"), error.localizedDescription)
        case .serverError(let code, let message):
            return String(format: String(localized: "Server error (%d): %@"), code, message)
        case .decodingError(let error):
            return String(format: String(localized: "Failed to parse server response: %@"), error.localizedDescription)
        }
    }

    /// User-friendly description suitable for display in activation dialogs
    var friendlyDescription: String {
        switch self {
        case .invalidKey:
            return String(localized: "That doesn't look like a valid license key. Check for typos and try again.")
        case .activationLimitReached:
            return String(localized: "This license has reached its activation limit. Deactivate another Mac first.")
        case .licenseExpired:
            return String(localized: "This license has expired. Renew it to continue using Pro features.")
        case .licenseSuspended:
            return String(localized: "This license has been suspended. Contact support for help.")
        case .networkError:
            return String(localized: "Could not reach the license server. Check your internet connection and try again.")
        case .serverError(let code, _):
            if code == 422 {
                return String(localized: "Invalid license key format. Check for typos and try again.")
            }
            return String(format: String(localized: "Something went wrong (error %d). Try again in a moment."), code)
        case .signatureInvalid, .publicKeyNotFound, .publicKeyInvalid:
            return String(localized: "License verification failed. Try updating the app to the latest version.")
        case .machineMismatch:
            return String(localized: "This license was activated on a different Mac. Activate it here to use Pro features.")
        case .notActivated:
            return String(localized: "This machine is not activated for this license.")
        case .decodingError:
            return String(localized: "Could not read the server response. Try again in a moment.")
        }
    }
}
