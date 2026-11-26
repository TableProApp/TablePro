import CloudKit
import Foundation
import os
import TableProFFI

// The transport the iOS engine calls (P1-I3, core ADR 0055). Each call, so each batch of an upload, first reads whether
// the organization still lets iCloud run, from the managed configuration as it stands rather than as the app last saw
// it. Once it does not, the shared transport closes, which cancels what is in flight, and nothing more reaches CloudKit
// until iCloud runs again. The coordinator closes it as well when the change reaches the app; this check holds the
// batches that start before that.
nonisolated final class PolicyCheckedCloudKitTransport: CloudKitTransport, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PolicyCheckedCloudKitTransport")

    private let base: CloudKitCoreTransport
    private let isAllowed: @Sendable () -> Bool

    init(base: CloudKitCoreTransport, isAllowed: @escaping @Sendable () -> Bool) {
        self.base = base
        self.isAllowed = isAllowed
    }

    private func admit() throws {
        guard isAllowed() else {
            if !base.isClosed {
                Self.logger.notice("The organization turned iCloud off, so nothing more is sent")
            }
            base.close()
            throw CloudKitFailure.Other(code: Int64(CKError.Code.operationCancelled.rawValue))
        }
    }

    func accountStatus() async throws -> CloudKitAccount {
        try admit()
        return try await base.accountStatus()
    }

    func ensureZone(account: String) async throws {
        try admit()
        try await base.ensureZone(account: account)
    }

    func deleteZone(account: String) async throws {
        try admit()
        try await base.deleteZone(account: account)
    }

    func fetchChanges(account: String, token: Data?) async throws -> CloudKitChanges {
        try admit()
        return try await base.fetchChanges(account: account, token: token)
    }

    func fetchRecords(account: String, names: [String]) async throws -> [CloudKitFetched] {
        try admit()
        return try await base.fetchRecords(account: account, names: names)
    }

    func modify(account: String, saves: [CloudKitRecord], deletes: [String]) async throws -> [CloudKitOutcome] {
        try admit()
        return try await base.modify(account: account, saves: saves, deletes: deletes)
    }
}
