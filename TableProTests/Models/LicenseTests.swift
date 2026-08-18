//
//  LicenseTests.swift
//  TablePro
//
//  Tests for License models and related types
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("License")
struct LicenseTests {
    private static let machineId = "9f86d081884c7d659a2feaa0c55ad015"

    private static func payload(
        status: String = "active",
        tier: String = "starter",
        expiresAt: String? = nil,
        issuedAt: String = "2024-01-01T00:00:00Z",
        email: String = "test@test.com",
        licenseKey: String = "test-key",
        billingCycle: String? = nil,
        teamId: String? = nil,
        role: String? = nil,
        machineId: String? = nil
    ) -> LicensePayloadData {
        LicensePayloadData(
            billingCycle: billingCycle,
            licenseKey: licenseKey,
            email: email,
            status: status,
            expiresAt: expiresAt,
            issuedAt: issuedAt,
            tier: tier,
            teamId: teamId,
            role: role,
            machineId: machineId
        )
    }

    private static func license(_ payload: LicensePayloadData) -> License {
        License(
            signedPayload: SignedLicensePayload(data: payload, signature: "sig"),
            cachedOnMachineId: machineId
        )
    }

    private static func isoString(daysAgo: Int) throws -> String {
        let date = try #require(Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - LicenseStatus.isValid Tests

    @Test("LicenseStatus.isValid returns true for active status")
    func licenseStatusActiveIsValid() {
        #expect(LicenseStatus.active.isValid == true)
    }

    @Test("LicenseStatus.isValid returns false for unlicensed status")
    func licenseStatusUnlicensedIsNotValid() {
        #expect(LicenseStatus.unlicensed.isValid == false)
    }

    @Test("LicenseStatus.isValid returns false for non-active statuses")
    func licenseStatusNonActiveIsNotValid() {
        #expect(LicenseStatus.expired.isValid == false)
        #expect(LicenseStatus.suspended.isValid == false)
        #expect(LicenseStatus.deactivated.isValid == false)
        #expect(LicenseStatus.validationFailed.isValid == false)
    }

    // MARK: - License.isExpired Tests

    @Test("isExpired returns false when the signed payload has no expiry")
    func isExpiredNilExpiresAt() {
        #expect(Self.license(Self.payload()).isExpired == false)
    }

    @Test("isExpired returns false when the signed expiry is in the future")
    func isExpiredFutureDate() throws {
        let license = Self.license(Self.payload(expiresAt: try Self.isoString(daysAgo: -30)))
        #expect(license.isExpired == false)
    }

    @Test("isExpired returns true when the signed expiry is in the past")
    func isExpiredPastDate() throws {
        let license = Self.license(Self.payload(expiresAt: try Self.isoString(daysAgo: 30)))
        #expect(license.isExpired == true)
    }

    // MARK: - License.daysSinceLastValidation Tests

    @Test("daysSinceLastValidation returns 0 when the payload was issued today")
    func daysSinceLastValidationToday() throws {
        let license = Self.license(Self.payload(issuedAt: try Self.isoString(daysAgo: 0)))
        #expect(license.daysSinceLastValidation == 0)
    }

    @Test("daysSinceLastValidation counts from the signed issue date, not from local state")
    func daysSinceLastValidationFiveDaysAgo() throws {
        let license = Self.license(Self.payload(issuedAt: try Self.isoString(daysAgo: 5)))
        #expect(license.daysSinceLastValidation == 5)
    }

    @Test("daysSinceLastValidation reads a payload issued in the future as 0, not as negative")
    func daysSinceLastValidationClampsFutureIssueDate() throws {
        let license = Self.license(Self.payload(issuedAt: try Self.isoString(daysAgo: -10)))
        #expect(license.daysSinceLastValidation == 0)
    }

    @Test("daysSinceLastValidation is nil when the signed issue date cannot be read")
    func daysSinceLastValidationUnparseableIssueDate() {
        let license = Self.license(Self.payload(issuedAt: "not-a-date"))
        #expect(license.daysSinceLastValidation == nil)
    }

    // MARK: - Status Mapping Tests

    @Test("License maps the signed active status")
    func licenseMapsActiveStatus() {
        #expect(Self.license(Self.payload(status: "active")).status == .active)
    }

    @Test("License maps the signed expired status")
    func licenseMapsExpiredStatus() {
        #expect(Self.license(Self.payload(status: "expired")).status == .expired)
    }

    @Test("License maps the signed suspended status")
    func licenseMapsSuspendedStatus() {
        #expect(Self.license(Self.payload(status: "suspended")).status == .suspended)
    }

    @Test("License maps an unknown signed status to validationFailed")
    func licenseMapsUnknownStatusToValidationFailed() {
        #expect(Self.license(Self.payload(status: "unknown")).status == .validationFailed)
    }

    // MARK: - Gating Reads Only the Signed Payload

    @Test("A cached blob whose outer fields claim Team over a signed Starter payload stays Starter")
    func forgedOuterFieldsAreIgnored() throws {
        let signed = Self.payload(status: "active", tier: "starter", expiresAt: "2024-01-01T00:00:00Z")
        let encoded = try JSONEncoder().encode(signed)
        let payloadJSON = try #require(String(data: encoded, encoding: .utf8))

        let forged = """
        {
            "key": "FORGED-KEY",
            "email": "attacker@example.com",
            "status": "active",
            "expiresAt": null,
            "lastValidatedAt": "2999-01-01T00:00:00Z",
            "machineId": "\(Self.machineId)",
            "tier": "team",
            "billingCycle": "lifetime",
            "signedPayload": { "data": \(payloadJSON), "signature": "sig" }
        }
        """

        let data = try #require(forged.data(using: .utf8))
        let decoded = try JSONDecoder().decode(License.self, from: data)

        #expect(decoded.tier == "starter")
        #expect(decoded.key == "test-key")
        #expect(decoded.email == "test@test.com")
        #expect(decoded.expiresAt != nil)
        #expect(decoded.isExpired == true)
        #expect(LicenseTier(rawValue: decoded.tier) == .starter)
    }

    @Test("A blob written by an older build still decodes and derives its values from the payload")
    func legacyBlobDecodes() throws {
        let signed = Self.payload(tier: "team", billingCycle: "yearly", teamId: "01JXYZ", role: "owner")
        let encoded = try JSONEncoder().encode(signed)
        let payloadJSON = try #require(String(data: encoded, encoding: .utf8))

        let legacy = """
        {
            "key": "test-key",
            "email": "test@test.com",
            "status": "active",
            "lastValidatedAt": "2024-01-01T00:00:00Z",
            "machineId": "\(Self.machineId)",
            "tier": "team",
            "billingCycle": "yearly",
            "signedPayload": { "data": \(payloadJSON), "signature": "sig" }
        }
        """

        let data = try #require(legacy.data(using: .utf8))
        let decoded = try JSONDecoder().decode(License.self, from: data)

        #expect(decoded.cachedOnMachineId == Self.machineId)
        #expect(decoded.tier == "team")
        #expect(decoded.billingCycle == "yearly")
        #expect(decoded.status == .active)
        #expect(decoded.boundMachineId == nil)
    }

    @Test("A saved envelope round-trips through the same two keys an older blob used")
    func envelopeRoundTrips() throws {
        let original = Self.license(Self.payload())
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(License.self, from: data) == original)

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = try #require(object).keys.sorted()
        #expect(keys == ["machineId", "signedPayload"])
    }

    // MARK: - LicensePayloadData Encoding Tests

    @Test("LicensePayloadData encodes all 7 fields in alphabetical order matching server format")
    func payloadDataEncodesAllFieldsAlphabetically() throws {
        let payloadData = LicensePayloadData(
            billingCycle: "monthly",
            licenseKey: "ABC-123",
            email: "user@example.com",
            status: "active",
            expiresAt: "2025-12-31T23:59:59Z",
            issuedAt: "2025-01-01T00:00:00Z",
            tier: "pro"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payloadData)
        let json = String(data: data, encoding: .utf8)

        guard let json else {
            Issue.record("Failed to encode payload data to UTF-8 string")
            return
        }

        guard let keys = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Failed to deserialize JSON as dictionary")
            return
        }

        let expectedKeys = ["billing_cycle", "email", "expires_at", "issued_at", "license_key", "status", "tier"]
        #expect(keys.keys.sorted() == expectedKeys)

        let billingCycleRange = json.range(of: "billing_cycle")
        let tierRange = json.range(of: "tier")
        guard let billingCycleRange, let tierRange else {
            Issue.record("Expected keys not found in JSON string")
            return
        }
        #expect(billingCycleRange.lowerBound < tierRange.lowerBound)
    }

    @Test("LicensePayloadData encodes nil billingCycle as null")
    func payloadDataEncodesNilBillingCycleAsNull() throws {
        let payloadData = LicensePayloadData(
            billingCycle: nil,
            licenseKey: "ABC-123",
            email: "user@example.com",
            status: "active",
            expiresAt: nil,
            issuedAt: "2025-01-01T00:00:00Z",
            tier: "starter"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payloadData)
        let json = String(data: data, encoding: .utf8)

        #expect(json?.contains("\"billing_cycle\":null") == true)
        #expect(json?.contains("\"expires_at\":null") == true)
    }

    @Test("LicensePayloadData omits team_id and role when nil so old payloads still verify")
    func payloadDataOmitsTeamFieldsWhenNil() throws {
        let payloadData = LicensePayloadData(
            billingCycle: nil,
            licenseKey: "ABC-123",
            email: "user@example.com",
            status: "active",
            expiresAt: nil,
            issuedAt: "2025-01-01T00:00:00Z",
            tier: "starter"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payloadData)

        guard let keys = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Failed to deserialize JSON as dictionary")
            return
        }
        #expect(keys["team_id"] == nil)
        #expect(keys["role"] == nil)
        #expect(keys.keys.count == 7)
    }

    @Test("LicensePayloadData encodes team_id and role for a Team license")
    func payloadDataEncodesTeamFields() throws {
        let payloadData = LicensePayloadData(
            billingCycle: "yearly",
            licenseKey: "ABC-123",
            email: "user@example.com",
            status: "active",
            expiresAt: "2026-12-31T23:59:59Z",
            issuedAt: "2026-01-01T00:00:00Z",
            tier: "team",
            teamId: "01JXYZ",
            role: "owner"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payloadData)

        guard let keys = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Failed to deserialize JSON as dictionary")
            return
        }
        #expect(keys["team_id"] as? String == "01JXYZ")
        #expect(keys["role"] as? String == "owner")
        #expect(keys.keys.count == 9)
    }

    @Test("LicensePayloadData round-trips team fields through Codable")
    func payloadDataRoundTripsTeamFields() throws {
        let original = LicensePayloadData(
            billingCycle: nil,
            licenseKey: "ABC-123",
            email: "user@example.com",
            status: "active",
            expiresAt: nil,
            issuedAt: "2026-01-01T00:00:00Z",
            tier: "team",
            teamId: "01JXYZ",
            role: "member"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LicensePayloadData.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - Signed Byte Contract

    /// The bytes the app verifies must be the bytes the server signed. The server does
    /// `ksort($data)` then `json_encode($data, JSON_UNESCAPED_SLASHES)`, so the key order is
    /// alphabetical and a forward slash stays raw. These are real outputs from that signer.
    private static func canonicalJSON(_ payload: LicensePayloadData) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(payload)
        return try #require(String(data: encoded, encoding: .utf8))
    }

    private static let slashPayload = LicensePayloadData(
        billingCycle: "yearly",
        licenseKey: "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE",
        email: "dev/ops@example.com",
        status: "active",
        expiresAt: "2027-01-01T00:00:00+00:00",
        issuedAt: "2026-08-18T10:00:00+00:00",
        tier: "team",
        teamId: "01JXYZ",
        role: "owner"
    )

    @Test("A signed field containing a slash encodes to the same bytes the server signed")
    func canonicalEncodingKeepsSlashesRaw() throws {
        let expected = "{\"billing_cycle\":\"yearly\",\"email\":\"dev/ops@example.com\","
            + "\"expires_at\":\"2027-01-01T00:00:00+00:00\",\"issued_at\":\"2026-08-18T10:00:00+00:00\","
            + "\"license_key\":\"AAAAA-BBBBB-CCCCC-DDDDD-EEEEE\",\"role\":\"owner\",\"status\":\"active\","
            + "\"team_id\":\"01JXYZ\",\"tier\":\"team\"}"

        #expect(try Self.canonicalJSON(Self.slashPayload) == expected)
    }

    @Test("A payload bound to a machine encodes machine_id in the server's sorted position")
    func canonicalEncodingIncludesBoundMachine() throws {
        let bound = LicensePayloadData(
            billingCycle: "yearly",
            licenseKey: "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE",
            email: "dev/ops@example.com",
            status: "active",
            expiresAt: "2027-01-01T00:00:00+00:00",
            issuedAt: "2026-08-18T10:00:00+00:00",
            tier: "team",
            teamId: "01JXYZ",
            role: "owner",
            machineId: "9f86d081884c7d659a2feaa0c55ad015"
        )

        let expected = "{\"billing_cycle\":\"yearly\",\"email\":\"dev/ops@example.com\","
            + "\"expires_at\":\"2027-01-01T00:00:00+00:00\",\"issued_at\":\"2026-08-18T10:00:00+00:00\","
            + "\"license_key\":\"AAAAA-BBBBB-CCCCC-DDDDD-EEEEE\","
            + "\"machine_id\":\"9f86d081884c7d659a2feaa0c55ad015\",\"role\":\"owner\",\"status\":\"active\","
            + "\"team_id\":\"01JXYZ\",\"tier\":\"team\"}"

        #expect(try Self.canonicalJSON(bound) == expected)
    }

    @Test("An unbound payload omits machine_id so a payload signed before binding still verifies")
    func payloadDataOmitsMachineIdWhenNil() throws {
        let data = try JSONEncoder().encode(Self.slashPayload)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = try #require(object)

        #expect(keys["machine_id"] == nil)
        #expect(keys.keys.count == 9)
    }

    @Test("A bound payload carries machine_id as a tenth key")
    func payloadDataEncodesMachineId() throws {
        let bound = LicensePayloadData(
            billingCycle: nil,
            licenseKey: "ABC-123",
            email: "user@example.com",
            status: "active",
            expiresAt: nil,
            issuedAt: "2026-01-01T00:00:00Z",
            tier: "starter",
            machineId: "abc123"
        )
        let data = try JSONEncoder().encode(bound)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = try #require(object)

        #expect(keys["machine_id"] as? String == "abc123")
        #expect(keys.keys.count == 8)
    }

    @Test("machine_id round-trips through Codable")
    func payloadDataRoundTripsMachineId() throws {
        let original = LicensePayloadData(
            billingCycle: nil,
            licenseKey: "ABC-123",
            email: "user@example.com",
            status: "active",
            expiresAt: nil,
            issuedAt: "2026-01-01T00:00:00Z",
            tier: "starter",
            machineId: "abc123"
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(LicensePayloadData.self, from: data) == original)
    }
}
