//
//  LicenseManagerDecisionTests.swift
//  TablePro
//
//  Tests for the pure licensing decisions: adopting a cached blob, the signed machine binding,
//  and what a server rejection means
//

import Foundation
@testable import TablePro
import Testing

@Suite("LicenseManagerDecision")
struct LicenseManagerDecisionTests {
    private static let thisMachine = "9f86d081884c7d659a2feaa0c55ad015"
    private static let otherMachine = "0000000000000000000000000000dead"

    private static func payload(machineId: String? = nil, tier: String = "starter") -> LicensePayloadData {
        LicensePayloadData(
            billingCycle: nil,
            licenseKey: "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE",
            email: "user@example.com",
            status: "active",
            expiresAt: nil,
            issuedAt: "2026-08-18T10:00:00+00:00",
            tier: tier,
            machineId: machineId
        )
    }

    private static func license(
        _ payload: LicensePayloadData,
        cachedOn machineId: String = thisMachine
    ) -> License {
        License(
            signedPayload: SignedLicensePayload(data: payload, signature: "sig"),
            cachedOnMachineId: machineId
        )
    }

    private static func validSignature(_ signed: SignedLicensePayload) throws -> LicensePayloadData {
        signed.data
    }

    private static func badSignature(_: SignedLicensePayload) throws -> LicensePayloadData {
        throw LicenseError.signatureInvalid
    }

    // MARK: - acceptsMachine

    @Test("A payload with no signed machine binding is accepted")
    func acceptsUnboundPayload() {
        #expect(LicenseManager.acceptsMachine(nil, current: Self.thisMachine))
    }

    @Test("A payload bound to this machine is accepted")
    func acceptsMatchingMachine() {
        #expect(LicenseManager.acceptsMachine(Self.thisMachine, current: Self.thisMachine))
    }

    @Test("A payload bound to another machine is refused")
    func refusesOtherMachine() {
        #expect(LicenseManager.acceptsMachine(Self.otherMachine, current: Self.thisMachine) == false)
    }

    // MARK: - resolveCachedLicense

    @Test("A cached blob with a valid signature on this machine is adopted")
    func adoptsValidCachedLicense() {
        let cached = Self.license(Self.payload())
        let resolution = LicenseManager.resolveCachedLicense(
            cached,
            currentMachineId: Self.thisMachine,
            verify: Self.validSignature
        )
        #expect(resolution == .accepted(cached))
    }

    @Test("A cached blob copied from another Mac's backup is rejected before the signature check")
    func rejectsCacheFromAnotherMachine() {
        let cached = Self.license(Self.payload(), cachedOn: Self.otherMachine)
        let resolution = LicenseManager.resolveCachedLicense(
            cached,
            currentMachineId: Self.thisMachine,
            verify: { signed in
                Issue.record("Signature must not be checked for another machine's cache")
                return signed.data
            }
        )
        #expect(resolution == .rejected(.cachedForAnotherMachine))
    }

    @Test("A payload the server bound to another Mac is rejected even when the envelope claims this one")
    func rejectsPayloadBoundElsewhere() {
        let cached = Self.license(Self.payload(machineId: Self.otherMachine))
        let resolution = LicenseManager.resolveCachedLicense(
            cached,
            currentMachineId: Self.thisMachine,
            verify: Self.validSignature
        )
        #expect(resolution == .rejected(.boundToAnotherMachine))
    }

    @Test("A payload the server bound to this Mac is adopted")
    func adoptsPayloadBoundHere() {
        let cached = Self.license(Self.payload(machineId: Self.thisMachine))
        let resolution = LicenseManager.resolveCachedLicense(
            cached,
            currentMachineId: Self.thisMachine,
            verify: Self.validSignature
        )
        #expect(resolution == .accepted(cached))
    }

    @Test("A cached blob with a bad signature is rejected")
    func rejectsBadSignature() {
        let cached = Self.license(Self.payload())
        let resolution = LicenseManager.resolveCachedLicense(
            cached,
            currentMachineId: Self.thisMachine,
            verify: Self.badSignature
        )
        #expect(resolution == .rejected(.signatureInvalid))
    }

    // MARK: - revocationStatus

    @Test("A suspended license reported by the server suspends it here")
    func mapsSuspended() {
        #expect(LicenseManager.revocationStatus(for: .licenseSuspended) == .suspended)
    }

    @Test("An expired license reported by the server expires it here")
    func mapsExpired() {
        #expect(LicenseManager.revocationStatus(for: .licenseExpired) == .expired)
    }

    @Test("A machine the server no longer has an activation for is deactivated here")
    func mapsNotActivated() {
        #expect(LicenseManager.revocationStatus(for: .notActivated) == .deactivated)
    }

    @Test("A payload minted for another machine is deactivated here")
    func mapsMachineMismatch() {
        #expect(LicenseManager.revocationStatus(for: .machineMismatch) == .deactivated)
    }

    @Test("A license key the server no longer knows leaves this Mac unlicensed")
    func mapsInvalidKey() {
        #expect(LicenseManager.revocationStatus(for: .invalidKey) == .unlicensed)
    }

    @Test("A transport failure is not a revocation, so the offline grace period still applies")
    func transportFailuresAreNotRevocations() {
        #expect(LicenseManager.revocationStatus(for: .networkError(URLError(.notConnectedToInternet))) == nil)
        #expect(LicenseManager.revocationStatus(for: .serverError(500, "Internal Server Error")) == nil)
        #expect(LicenseManager.revocationStatus(for: .serverError(404, "Not Found")) == nil)
        #expect(LicenseManager.revocationStatus(for: .signatureInvalid) == nil)
        #expect(LicenseManager.revocationStatus(for: .activationLimitReached) == nil)
    }

    // MARK: - resolveStatus

    private static func resolve(
        signedStatus: LicenseStatus = .active,
        isExpired: Bool = false,
        daysSinceValidation: Int? = 0,
        serverRejection: LicenseStatus? = nil,
        hasRecentServerContact: Bool = false
    ) -> LicenseStatus {
        LicenseManager.resolveStatus(
            signedStatus: signedStatus,
            isExpired: isExpired,
            daysSinceValidation: daysSinceValidation,
            gracePeriodDays: 30,
            serverRejection: serverRejection,
            hasRecentServerContact: hasRecentServerContact
        )
    }

    @Test("A signed, unexpired, recently validated license is active")
    func resolvesActive() {
        #expect(Self.resolve() == .active)
    }

    @Test("A server rejection outranks everything the payload says")
    func serverRejectionWins() {
        #expect(Self.resolve(serverRejection: .suspended) == .suspended)
        #expect(Self.resolve(signedStatus: .active, serverRejection: .deactivated) == .deactivated)
        #expect(Self.resolve(serverRejection: .expired, hasRecentServerContact: true) == .expired)
    }

    @Test("A signed status this build does not recognise withholds access instead of granting it")
    func unrecognisedSignedStatusFailsClosed() {
        #expect(Self.resolve(signedStatus: .validationFailed) == .validationFailed)
        #expect(Self.resolve(signedStatus: .unlicensed) == .unlicensed)
        #expect(Self.resolve(signedStatus: .suspended) == .suspended)
        #expect(Self.resolve(signedStatus: .expired) == .expired)
        #expect(Self.resolve(signedStatus: .deactivated) == .deactivated)
    }

    @Test("A license past its signed expiry is expired")
    func resolvesExpiry() {
        #expect(Self.resolve(isExpired: true) == .expired)
    }

    @Test("Grace runs out 30 days after the signed issue date, and not before")
    func resolvesGracePeriod() {
        #expect(Self.resolve(daysSinceValidation: 30) == .active)
        #expect(Self.resolve(daysSinceValidation: 31) == .validationFailed)
    }

    @Test("A server that answered this session keeps a stale-looking issue date from failing grace")
    func recentContactSuppressesStaleIssueDate() {
        #expect(Self.resolve(daysSinceValidation: 400, hasRecentServerContact: true) == .active)
        #expect(Self.resolve(daysSinceValidation: 400, hasRecentServerContact: false) == .validationFailed)
    }

    @Test("An unreadable signed issue date does not by itself fail the grace period")
    func unreadableIssueDateDoesNotFailGrace() {
        #expect(Self.resolve(daysSinceValidation: nil) == .active)
    }
}
