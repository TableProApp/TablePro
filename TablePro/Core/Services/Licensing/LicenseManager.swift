//
//  LicenseManager.swift
//  TablePro
//
//  Orchestrates license activation, offline verification, and periodic re-validation
//

import Combine
import Foundation
import Observation
import os

/// Why a cached license blob was not adopted at launch.
internal enum CachedLicenseRejection: Equatable {
    case cachedForAnotherMachine
    case boundToAnotherMachine
    case signatureInvalid

    var logDescription: String {
        switch self {
        case .cachedForAnotherMachine: return "cached for another machine"
        case .boundToAnotherMachine: return "signed for another machine"
        case .signatureInvalid: return "signature invalid"
        }
    }
}

/// Outcome of checking a cached license blob before trusting it.
internal enum CachedLicenseResolution: Equatable {
    case accepted(License)
    case rejected(CachedLicenseRejection)
}

/// Manages the app's license state with offline-first verification
@MainActor @Observable
final class LicenseManager {
    static let shared = LicenseManager()

    private static let logger = Logger(subsystem: "com.TablePro", category: "LicenseManager")

    /// Current cached license (nil = unlicensed)
    private(set) var license: License?

    /// Current license status
    private(set) var status: LicenseStatus = .unlicensed

    /// Whether a network operation is in progress
    private(set) var isValidating: Bool = false

    /// Last error from an operation (cleared on success)
    private(set) var lastError: LicenseError?

    private let storage = LicenseStorage.shared
    private let apiClient = LicenseAPIClient.shared
    private let verifier = LicenseSignatureVerifier.shared

    /// Re-validation interval: 7 days
    private let revalidationInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Grace period: 30 days without server contact before forcing re-validation
    private let gracePeriodDays = 30

    /// What the server last told us about this license, when that was a rejection rather than a
    /// new payload. Deliberately not persisted: it can only take entitlement away, and writing it
    /// to disk would put licensing state back outside the signature.
    private var serverRejection: LicenseStatus?

    /// When the server last confirmed this license, measured by this Mac's clock. Held in memory
    /// only, so nothing on disk can forge it and a relaunch falls back to the signed issue date.
    /// It exists so a server clock far behind the Mac cannot expire the grace period on a license
    /// the server has just approved.
    private var lastServerContact: Date?

    @ObservationIgnored private var revalidationTask: Task<Void, Never>?

    private init() {
        loadCachedLicense()
    }

    deinit {
        revalidationTask?.cancel()
    }

    // MARK: - Startup

    /// Load cached license from storage and re-verify its signature offline
    private func loadCachedLicense() {
        guard let cached = storage.loadLicense() else {
            status = .unlicensed
            return
        }

        let resolution = Self.resolveCachedLicense(
            cached,
            currentMachineId: storage.machineId,
            verify: verifier.verify(payload:)
        )

        switch resolution {
        case .accepted(let accepted):
            license = accepted
            evaluateStatus()
            Self.logger.trace("Loaded cached license for \(accepted.email)")
        case .rejected(let reason):
            Self.logger.error("Cached license rejected (\(reason.logDescription)), clearing")
            storage.clearAll()
            license = nil
            status = .unlicensed
        }
    }

    /// Verify a signed payload and refuse one the server minted for a different Mac.
    /// Every path that trusts a payload goes through here.
    private func verifiedPayload(from signed: SignedLicensePayload) throws -> LicensePayloadData {
        let data = try verifier.verify(payload: signed)

        guard Self.acceptsMachine(data.machineId, current: storage.machineId) else {
            throw LicenseError.machineMismatch
        }

        return data
    }

    /// A payload without a signed machine binding predates the binding and is accepted.
    nonisolated static func acceptsMachine(_ bound: String?, current: String) -> Bool {
        guard let bound else { return true }
        return bound == current
    }

    /// Whether a cached blob may be adopted, decided without touching storage so it can be tested.
    nonisolated static func resolveCachedLicense(
        _ cached: License,
        currentMachineId: String,
        verify: (SignedLicensePayload) throws -> LicensePayloadData
    ) -> CachedLicenseResolution {
        guard cached.cachedOnMachineId == currentMachineId else {
            return .rejected(.cachedForAnotherMachine)
        }

        guard let verified = try? verify(cached.signedPayload) else {
            return .rejected(.signatureInvalid)
        }

        guard acceptsMachine(verified.machineId, current: currentMachineId) else {
            return .rejected(.boundToAnotherMachine)
        }

        return .accepted(cached)
    }

    /// Start periodic re-validation. Call from AppDelegate.applicationDidFinishLaunching.
    func startPeriodicValidation() {
        revalidationTask?.cancel()
        revalidationTask = Task { [weak self] in
            // Check if revalidation is needed right now
            if let self, let license = self.license,
               (license.daysSinceLastValidation ?? .max) >= Int(self.revalidationInterval / 86_400) {
                await self.revalidate()
            }

            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.revalidationInterval))
                await self.revalidate()
            }
        }
    }

    // MARK: - Activation

    /// Activate a license key on this machine
    /// Activates from either a license key or a team invite code, auto-detecting which was entered.
    /// Every activation entry point routes through here so the settings pane and the standalone sheet
    /// behave identically.
    func activate(codeOrKey: String) async throws {
        let trimmed = codeOrKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isLicenseKey(trimmed) {
            try await activate(licenseKey: trimmed)
        } else {
            try await activate(inviteCode: trimmed)
        }
    }

    /// A license key looks like XXXXX-XXXXX-XXXXX-XXXXX-XXXXX; anything else is treated as an invite code.
    nonisolated static func isLicenseKey(_ value: String) -> Bool {
        let pattern = "^[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}$"
        return value.uppercased().range(of: pattern, options: .regularExpression) != nil
    }

    func activate(licenseKey: String) async throws {
        let trimmedKey = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmedKey.isEmpty else {
            throw LicenseError.invalidKey
        }

        isValidating = true
        lastError = nil
        defer { isValidating = false }

        let appVersion = Bundle.main.appVersion
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        let request = LicenseActivationRequest(
            licenseKey: trimmedKey,
            machineId: storage.machineId,
            machineName: storage.machineName,
            appVersion: appVersion,
            osVersion: osVersion
        )

        do {
            let signedPayload = try await apiClient.activate(request: request)

            let payloadData = try verifiedPayload(from: signedPayload)

            let newLicense = License(signedPayload: signedPayload, cachedOnMachineId: storage.machineId)

            storage.saveLicenseKey(trimmedKey)
            storage.saveLicense(newLicense)

            license = newLicense
            acceptServerConfirmation()

            Self.logger.info("License activated for \(payloadData.email)")
        } catch let error as LicenseError {
            lastError = error
            throw error
        } catch {
            let licenseError = LicenseError.networkError(error)
            lastError = licenseError
            throw licenseError
        }
    }

    /// Join a team by accepting an invitation, activating this machine as a member
    func activate(inviteCode: String) async throws {
        let trimmedCode = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            throw LicenseError.invalidKey
        }

        isValidating = true
        lastError = nil
        defer { isValidating = false }

        let request = LicenseAcceptInviteRequest(
            token: trimmedCode,
            machineId: storage.machineId,
            machineName: storage.machineName,
            appVersion: Bundle.main.appVersion,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )

        do {
            let signedPayload = try await apiClient.acceptInvite(request: request)

            let payloadData = try verifiedPayload(from: signedPayload)

            let newLicense = License(signedPayload: signedPayload, cachedOnMachineId: storage.machineId)

            storage.saveLicenseKey(newLicense.key)
            storage.saveLicense(newLicense)

            license = newLicense
            acceptServerConfirmation()

            Self.logger.info("Joined team via invitation for \(payloadData.email)")
        } catch let error as LicenseError {
            lastError = error
            throw error
        } catch {
            let licenseError = LicenseError.networkError(error)
            lastError = licenseError
            throw licenseError
        }
    }

    // MARK: - Deactivation

    /// Deactivate the license on this machine
    @discardableResult
    func deactivate() async -> Bool {
        guard let license else { return true }

        isValidating = true
        lastError = nil
        defer { isValidating = false }

        let request = LicenseDeactivationRequest(
            licenseKey: license.key,
            machineId: storage.machineId
        )

        var serverSuccess = true
        do {
            try await apiClient.deactivate(request: request)
        } catch {
            Self.logger.warning("Server deactivation failed: \(error.localizedDescription)")
            serverSuccess = false
        }

        storage.clearAll()
        self.license = nil
        serverRejection = nil
        lastServerContact = nil
        status = .deactivated

        revalidationTask?.cancel()
        revalidationTask = nil

        Self.logger.info("License deactivated locally (server: \(serverSuccess ? "ok" : "failed"))")
        return serverSuccess
    }

    // MARK: - Re-validation

    var isExpiringSoon: Bool {
        guard let days = license?.daysUntilExpiry else { return false }
        return days >= 0 && days <= 7
    }

    var daysUntilExpiry: Int? {
        license?.daysUntilExpiry
    }

    /// Periodic re-validation: refresh license from server, fall back to offline grace period
    func revalidate() async {
        guard let license else { return }

        isValidating = true
        defer { isValidating = false }

        let request = LicenseValidationRequest(
            licenseKey: license.key,
            machineId: storage.machineId,
            machineName: storage.machineName,
            appVersion: Bundle.main.appVersion,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )

        do {
            let signedPayload = try await apiClient.validate(request: request)
            _ = try verifiedPayload(from: signedPayload)

            let updatedLicense = License(signedPayload: signedPayload, cachedOnMachineId: storage.machineId)

            storage.saveLicense(updatedLicense)
            self.license = updatedLicense
            lastError = nil
            acceptServerConfirmation()

            await TeamLibrarySyncCoordinator.shared.pullIfNeeded()

            Self.logger.trace("License re-validated successfully")
        } catch {
            let licenseError = error as? LicenseError ?? .networkError(error)

            if let rejection = Self.revocationStatus(for: licenseError) {
                Self.logger.error("License rejected by server: \(licenseError.localizedDescription)")
                serverRejection = rejection
            } else {
                Self.logger.warning("Re-validation failed: \(licenseError.localizedDescription)")
            }

            lastError = licenseError
            evaluateStatus()
        }
    }

    /// The status the server's own rejection implies, or nil when the request simply did not
    /// reach it. Only a rejection the server actually spoke changes entitlement; a transport
    /// failure falls through to the offline grace period.
    nonisolated static func revocationStatus(for error: LicenseError) -> LicenseStatus? {
        switch error {
        case .licenseSuspended:
            return .suspended
        case .licenseExpired:
            return .expired
        case .notActivated, .machineMismatch:
            return .deactivated
        case .invalidKey:
            return .unlicensed
        default:
            return nil
        }
    }

    private func acceptServerConfirmation() {
        serverRejection = nil
        lastServerContact = Date()
        evaluateStatus()
    }

    /// Whether this Mac has heard from the server recently enough to keep the license running,
    /// which covers a freshly issued payload whose signed issue date looks stale to us.
    private var isWithinLocalGracePeriod: Bool {
        guard let lastServerContact else { return false }
        return Date().timeIntervalSince(lastServerContact) <= Double(gracePeriodDays) * 86_400
    }

    // MARK: - Status Evaluation

    /// Evaluate current license status based on expiration, grace period, and signature validity
    private func evaluateStatus() {
        let previousStatus = status
        defer { notifyIfChanged(from: previousStatus) }

        guard let license else {
            status = .unlicensed
            return
        }

        status = Self.resolveStatus(
            signedStatus: license.status,
            isExpired: license.isExpired,
            daysSinceValidation: license.daysSinceLastValidation,
            gracePeriodDays: gracePeriodDays,
            serverRejection: serverRejection,
            hasRecentServerContact: isWithinLocalGracePeriod
        )
    }

    /// Pure resolution of the effective status. Kept static and side-effect free so the whole grid
    /// can be tested without constructing a LicenseManager, the same way `resolveAccess` is.
    /// Only a signed `active` may go on to be treated as active, so a status this build does not
    /// recognise withholds access rather than granting it.
    nonisolated static func resolveStatus(
        signedStatus: LicenseStatus,
        isExpired: Bool,
        daysSinceValidation: Int?,
        gracePeriodDays: Int,
        serverRejection: LicenseStatus?,
        hasRecentServerContact: Bool
    ) -> LicenseStatus {
        if let serverRejection {
            return serverRejection
        }

        guard signedStatus == .active else {
            return signedStatus
        }

        if isExpired {
            return .expired
        }

        // An unreadable issue date is left to the revalidation scheduler, which treats it as due,
        // rather than counted against a license that may be fine.
        if (daysSinceValidation ?? 0) > gracePeriodDays, !hasRecentServerContact {
            return .validationFailed
        }

        return .active
    }

    private func notifyIfChanged(from previousStatus: LicenseStatus) {
        if status != previousStatus {
            AppEvents.shared.licenseStatusDidChange.send(())
        }
    }
}
