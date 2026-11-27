//
//  SyncProviderCoordinator+Rules.swift
//  TablePro
//

import Foundation
import TableProFFI
import TableProSyncTransport

// The Mac's rules that read nothing but their arguments, and the record cache the Swift engine left.
extension SyncProviderCoordinator {
    nonisolated static func makeRecordCache() -> SyncRecordCache {
        SyncRecordCache(
            directory: AppStorageEnvironment.shared.supportDirectory
                .appendingPathComponent("SyncRecordCache", isDirectory: true),
            defaults: AppStorageEnvironment.shared.defaults
        )
    }

    // Exhaustive, so a paying customer the app could not reach the server about is never told to buy.
    nonisolated static func licenseDisableReason(for access: ProFeatureAccess) -> DisableReason? {
        switch access {
        case .available:
            return nil
        case .expired:
            return .licenseExpired
        case .refreshFailed:
            return .licenseUnverified
        case .signedOut, .notIncluded:
            return .licenseRequired
        }
    }

    // The kinds this Mac's switches leave out, and whether passwords ride along. A connection project groups connections,
    // so it goes with them. The password switch holds on either provider: `syncsPasswords` also asks for iCloud on, which
    // TablePro Sync turns off, and envelopes would then never sync.
    nonisolated static func categories(_ settings: SyncSettings) -> SyncCategoriesArg {
        var off = SyncRecordType.allCases
            .filter { !settings.syncs($0) || keptInSwift.contains($0) }
            .map(\.coreKind)
        if !settings.syncConnections, !off.contains(connectionProjectKind) {
            off.append(connectionProjectKind)
        }
        return SyncCategoriesArg(offKinds: off, passwords: settings.syncConnections && settings.syncPasswords)
    }

    nonisolated static let connectionProjectKind = SyncRecordType.project.coreKind

    // Kinds whose Mac store is still Swift's, so the core's store holds none of them: an adapter over it would read every
    // record as deleted. An off kind rests and pushes nothing. Each goes once M2 moves its store into the core.
    nonisolated static let keptInSwift: Set<SyncRecordType> = [.sshProfile, .credentialProfile]
}
