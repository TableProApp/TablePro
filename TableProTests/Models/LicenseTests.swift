//
//  LicenseTests.swift
//  TablePro
//
//  Tests for License models and related types
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("License")
struct LicenseTests {
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

    @Test("isExpired returns false when expiresAt is nil")
    func isExpiredNilExpiresAt() {
        let license = License(
            key: "test-key",
            email: "test@test.com",
            status: .active,
            expiresAt: nil,
            lastValidatedAt: Date(),
            machineId: "machine1",
            signedPayload: SignedLicensePayload(
                data: LicensePayloadData(
                    billingCycle: nil,
                    licenseKey: "test-key",
                    email: "test@test.com",
                    status: "active",
                    expiresAt: nil,
                    issuedAt: "2024-01-01T00:00:00Z",
                    tier: "starter"
                ),
                signature: "sig"
            ),
            tier: "starter"
        )
        #expect(license.isExpired == false)
    }

    @Test("isExpired returns false when expiresAt is in the future")
    func isExpiredFutureDate() {
        let futureDate = Date().addingTimeInterval(86_400 * 30)
        let license = License(
            key: "test-key",
            email: "test@test.com",
            status: .active,
            expiresAt: futureDate,
            lastValidatedAt: Date(),
            machineId: "machine1",
            signedPayload: SignedLicensePayload(
                data: LicensePayloadData(
                    billingCycle: nil,
                    licenseKey: "test-key",
                    email: "test@test.com",
                    status: "active",
                    expiresAt: "2025-01-01T00:00:00Z",
                    issuedAt: "2024-01-01T00:00:00Z",
                    tier: "starter"
                ),
                signature: "sig"
            ),
            tier: "starter"
        )
        #expect(license.isExpired == false)
    }

    @Test("isExpired returns true when expiresAt is in the past")
    func isExpiredPastDate() {
        let pastDate = Date().addingTimeInterval(-86_400 * 30)
        let license = License(
            key: "test-key",
            email: "test@test.com",
            status: .expired,
            expiresAt: pastDate,
            lastValidatedAt: Date(),
            machineId: "machine1",
            signedPayload: SignedLicensePayload(
                data: LicensePayloadData(
                    billingCycle: nil,
                    licenseKey: "test-key",
                    email: "test@test.com",
                    status: "expired",
                    expiresAt: "2024-01-01T00:00:00Z",
                    issuedAt: "2023-01-01T00:00:00Z",
                    tier: "starter"
                ),
                signature: "sig"
            ),
            tier: "starter"
        )
        #expect(license.isExpired == true)
    }

    // MARK: - License.daysSinceLastValidation Tests

    @Test("daysSinceLastValidation returns 0 when lastValidatedAt is today")
    func daysSinceLastValidationToday() {
        let license = License(
            key: "test-key",
            email: "test@test.com",
            status: .active,
            expiresAt: nil,
            lastValidatedAt: Date(),
            machineId: "machine1",
            signedPayload: SignedLicensePayload(
                data: LicensePayloadData(
                    billingCycle: nil,
                    licenseKey: "test-key",
                    email: "test@test.com",
                    status: "active",
                    expiresAt: nil,
                    issuedAt: "2024-01-01T00:00:00Z",
                    tier: "starter"
                ),
                signature: "sig"
            ),
            tier: "starter"
        )
        #expect(license.daysSinceLastValidation == 0)
    }

    @Test("daysSinceLastValidation returns correct days when lastValidatedAt is 5 days ago")
    func daysSinceLastValidationFiveDaysAgo() {
        guard let fiveDaysAgo = Calendar.current.date(byAdding: .day, value: -5, to: Date()) else {
            Issue.record("Failed to create date 5 days ago")
            return
        }
        let license = License(
            key: "test-key",
            email: "test@test.com",
            status: .active,
            expiresAt: nil,
            lastValidatedAt: fiveDaysAgo,
            machineId: "machine1",
            signedPayload: SignedLicensePayload(
                data: LicensePayloadData(
                    billingCycle: nil,
                    licenseKey: "test-key",
                    email: "test@test.com",
                    status: "active",
                    expiresAt: nil,
                    issuedAt: "2024-01-01T00:00:00Z",
                    tier: "starter"
                ),
                signature: "sig"
            ),
            tier: "starter"
        )
        #expect(license.daysSinceLastValidation == 5)
    }

    // MARK: - License.from Status Mapping Tests

    @Test("License.from maps active status correctly")
    func licenseFromMapsActiveStatus() {
        let payloadData = LicensePayloadData(
            billingCycle: nil,
            licenseKey: "test-key",
            email: "test@test.com",
            status: "active",
            expiresAt: nil,
            issuedAt: "2024-01-01T00:00:00Z",
            tier: "starter"
        )
        let signedPayload = SignedLicensePayload(data: payloadData, signature: "sig")
        let license = License.from(
            payload: payloadData,
            signedPayload: signedPayload,
            machineId: "machine1"
        )
        #expect(license.status == .active)
    }

    @Test("License.from maps expired status correctly")
    func licenseFromMapsExpiredStatus() {
        let payloadData = LicensePayloadData(
            billingCycle: "monthly",
            licenseKey: "test-key",
            email: "test@test.com",
            status: "expired",
            expiresAt: "2024-01-01T00:00:00Z",
            issuedAt: "2023-01-01T00:00:00Z",
            tier: "starter"
        )
        let signedPayload = SignedLicensePayload(data: payloadData, signature: "sig")
        let license = License.from(
            payload: payloadData,
            signedPayload: signedPayload,
            machineId: "machine1"
        )
        #expect(license.status == .expired)
    }

    @Test("License.from maps suspended status correctly")
    func licenseFromMapsSuspendedStatus() {
        let payloadData = LicensePayloadData(
            billingCycle: nil,
            licenseKey: "test-key",
            email: "test@test.com",
            status: "suspended",
            expiresAt: nil,
            issuedAt: "2024-01-01T00:00:00Z",
            tier: "starter"
        )
        let signedPayload = SignedLicensePayload(data: payloadData, signature: "sig")
        let license = License.from(
            payload: payloadData,
            signedPayload: signedPayload,
            machineId: "machine1"
        )
        #expect(license.status == .suspended)
    }

    @Test("License.from maps unknown status to validationFailed")
    func licenseFromMapsUnknownStatusToValidationFailed() {
        let payloadData = LicensePayloadData(
            billingCycle: nil,
            licenseKey: "test-key",
            email: "test@test.com",
            status: "unknown",
            expiresAt: nil,
            issuedAt: "2024-01-01T00:00:00Z",
            tier: "starter"
        )
        let signedPayload = SignedLicensePayload(data: payloadData, signature: "sig")
        let license = License.from(
            payload: payloadData,
            signedPayload: signedPayload,
            machineId: "machine1"
        )
        #expect(license.status == .validationFailed)
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
}
