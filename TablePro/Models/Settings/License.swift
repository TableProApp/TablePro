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

    private enum CodingKeys: String, CodingKey {
        case billingCycle = "billing_cycle"
        case licenseKey = "license_key"
        case email
        case status
        case expiresAt = "expires_at"
        case issuedAt = "issued_at"
        case tier
    }

    /// Custom encode to explicitly write null for nil optionals.
    /// The auto-synthesized Codable uses encodeIfPresent which omits nil keys,
    /// but PHP's json_encode includes null values — the signed JSON must match exactly.
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

/// Request body for license validation
struct LicenseValidationRequest: Codable {
    let licenseKey: String
    let machineId: String

    private enum CodingKeys: String, CodingKey {
        case licenseKey = "license_key"
        case machineId = "machine_id"
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

/// Local cached license with metadata for offline use
struct License: Codable, Equatable {
    var key: String
    var email: String
    var status: LicenseStatus
    var expiresAt: Date?
    var lastValidatedAt: Date
    var machineId: String
    var signedPayload: SignedLicensePayload
    var tier: String
    var billingCycle: String?

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

    /// Days since last successful server validation
    var daysSinceLastValidation: Int {
        Calendar.current.dateComponents([.day], from: lastValidatedAt, to: Date()).day ?? 0
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Create a License from a verified server payload
    static func from(
        payload: LicensePayloadData,
        signedPayload: SignedLicensePayload,
        machineId: String
    ) -> License {
        let expiresAt = payload.expiresAt.flatMap { iso8601Formatter.date(from: $0) }
        let status: LicenseStatus = switch payload.status {
        case "active": .active
        case "expired": .expired
        case "suspended": .suspended
        default: .validationFailed
        }

        return License(
            key: payload.licenseKey,
            email: payload.email,
            status: status,
            expiresAt: expiresAt,
            lastValidatedAt: Date(),
            machineId: machineId,
            signedPayload: signedPayload,
            tier: payload.tier,
            billingCycle: payload.billingCycle
        )
    }
}

// MARK: - License Error

/// Errors that can occur during license operations
enum LicenseError: LocalizedError {
    case invalidKey
    case signatureInvalid
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
            return "The license key is invalid."
        case .signatureInvalid:
            return "License signature verification failed."
        case .publicKeyNotFound:
            return "License public key not found in app bundle."
        case .publicKeyInvalid:
            return "License public key is invalid."
        case .activationLimitReached:
            return "Maximum number of activations reached."
        case .licenseExpired:
            return "The license has expired."
        case .licenseSuspended:
            return "The license has been suspended."
        case .notActivated:
            return "This machine is not activated."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        case .decodingError(let error):
            return "Failed to parse server response: \(error.localizedDescription)"
        }
    }
}
