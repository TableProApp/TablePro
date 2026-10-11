import CloudKit
import Foundation
import os

public struct PullResult: Sendable {
    public let changedRecords: [CKRecord]
    public let deletedRecordIDs: [CKRecord.ID]
    public let newToken: CKServerChangeToken?

    public init(changedRecords: [CKRecord], deletedRecordIDs: [CKRecord.ID], newToken: CKServerChangeToken?) {
        self.changedRecords = changedRecords
        self.deletedRecordIDs = deletedRecordIDs
        self.newToken = newToken
    }
}

public actor CloudKitSyncEngine {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CloudKitSyncEngine")

    private let container: CKContainer?
    private let database: CKDatabase?
    private let zoneID: CKRecordZone.ID

    public static let zoneName = "TableProSync"
    public static let defaultContainerID = "iCloud.com.TablePro"

    private static let maxRetries = 3

    /// What a build without the iCloud entitlement reports, in CloudKit's own terms, so it is
    /// classified like the server's answer to the same fault.
    private static var unavailable: CKError { CKError(.missingEntitlement) }

    public static func hasICloudEntitlement() -> Bool {
        CloudKitEntitlement.isGrantedToCurrentProcess()
    }

    public init(containerIdentifier: String = defaultContainerID) {
        if Self.hasICloudEntitlement() {
            let container = CKContainer(identifier: containerIdentifier)
            self.container = container
            database = container.privateCloudDatabase
        } else {
            container = nil
            database = nil
            Self.logger.warning("iCloud entitlement missing: CloudKit sync disabled")
        }
        zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    public var currentZoneID: CKRecordZone.ID { zoneID }

    // MARK: - Account Status

    public func accountStatus() async throws -> CKAccountStatus {
        guard let container else { throw Self.unavailable }
        return try await container.accountStatus()
    }

    public func currentAccountId() async throws -> String {
        guard let container else { throw Self.unavailable }
        return try await container.userRecordID().recordName
    }

    // MARK: - Zone Management

    public func ensureZoneExists() async throws {
        guard let database else { throw Self.unavailable }
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await withRetry {
            try await database.save(zone)
        }
        Self.logger.trace("Created or confirmed sync zone: \(Self.zoneName)")
    }

    // MARK: - Push

    @discardableResult
    public func push(records: [CKRecord], deletions: [CKRecord.ID]) async throws -> PushOutcome {
        let withheldTypes = SyncSchemaGate.withheldRecordTypes(in: records)
        if !withheldTypes.isEmpty {
            Self.logger.error(
                "Withholding record types absent from the production schema: \(withheldTypes.sorted().joined(separator: ", "), privacy: .public)"
            )
        }

        let publishableRecords = SyncSchemaGate.publishable(records: records)
        let publishableDeletions = SyncSchemaGate.publishable(deletions: deletions)
        guard !publishableRecords.isEmpty || !publishableDeletions.isEmpty else { return PushOutcome() }

        var outcome = PushOutcome()
        let plans = SyncPushBatchPlanner.plans(
            saveCount: publishableRecords.count,
            deletionCount: publishableDeletions.count
        )

        for plan in plans {
            do {
                outcome.merge(try await push(
                    plan: plan,
                    records: publishableRecords,
                    deletions: publishableDeletions
                ))
            } catch {
                throw SyncPushInterruption.after(outcome, failingWith: error)
            }
            /// Full storage, a signed-out account or a deleted zone fails every item that follows the
            /// same way. The unsent items stay pending, exactly as the failed ones do.
            if let failure = outcome.failure, failure.stopsUpload {
                Self.logger.notice("Stopped the upload after a batch every later one would fail the same way")
                break
            }
        }

        let saved = outcome.savedRecords.count
        let deleted = outcome.deletedRecordIDs.count
        let failed = outcome.failures.count
        Self.logger.info("Pushed \(saved) records, \(deleted) deletions, \(failed) rejected")

        let failuresByCode = Dictionary(grouping: outcome.failures.values, by: \.code)
        for (code, failures) in failuresByCode {
            let example = failures.first?.message ?? ""
            Self.logger.error(
                "CloudKit rejected \(failures.count, privacy: .public) items with code \(code.rawValue, privacy: .public), for example: \(example)"
            )
        }

        return outcome
    }

    private func push(
        plan: SyncPushBatchPlan,
        records: [CKRecord],
        deletions: [CKRecord.ID]
    ) async throws -> PushOutcome {
        guard !plan.isEmpty else { return PushOutcome() }

        do {
            return try await pushBatch(
                records: Array(records[plan.saves]),
                deletions: Array(deletions[plan.deletions])
            )
        } catch let error as CKError where error.code == .limitExceeded {
            let halves = SyncPushBatchPlanner.halves(of: plan)
            guard !halves.isEmpty else { throw error }

            Self.logger.notice(
                "CloudKit refused a batch of \(plan.itemCount, privacy: .public) items, splitting it"
            )

            var outcome = PushOutcome()
            for half in halves {
                do {
                    outcome.merge(try await push(plan: half, records: records, deletions: deletions))
                } catch {
                    throw SyncPushInterruption.after(outcome, failingWith: error)
                }
                if let failure = outcome.failure, failure.stopsUpload { break }
            }
            return outcome
        }
    }

    private func pushBatch(records: [CKRecord], deletions: [CKRecord.ID]) async throws -> PushOutcome {
        guard let database else { throw Self.unavailable }
        return try await withRetry {
            let operation = CKModifyRecordsOperation(
                recordsToSave: records,
                recordIDsToDelete: deletions
            )
            operation.savePolicy = .changedKeys
            operation.isAtomic = false

            return try await withCheckedThrowingContinuation { continuation in
                var outcome = PushOutcome()

                operation.perRecordSaveBlock = { recordID, result in
                    switch result {
                    case .success(let record):
                        outcome.recordSave(record)
                    case .failure(let error):
                        outcome.recordFailure(SyncItemFailure(error: error), for: recordID)
                    }
                }

                operation.perRecordDeleteBlock = { recordID, result in
                    switch result {
                    case .success:
                        outcome.recordDeletion(recordID)
                    case .failure(let error):
                        outcome.recordFailure(SyncItemFailure(error: error), for: recordID)
                    }
                }

                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume(returning: outcome)
                    case .failure(let error):
                        guard let ckError = error as? CKError, ckError.code == .partialFailure else {
                            continuation.resume(throwing: error)
                            return
                        }
                        outcome.absorbPartialErrors(from: ckError)
                        continuation.resume(returning: outcome)
                    }
                }

                database.add(operation)
            }
        }
    }

    // MARK: - Pull

    public func pull(since token: CKServerChangeToken?) async throws -> PullResult {
        var changedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecord.ID] = []
        var cursor = token

        while true {
            let page = try await withRetry { [cursor] in
                try await performPull(since: cursor)
            }

            changedRecords.append(contentsOf: page.result.changedRecords)
            deletedRecordIDs.append(contentsOf: page.result.deletedRecordIDs)
            cursor = page.result.newToken ?? cursor

            guard page.moreComing, page.result.newToken != nil else {
                return PullResult(
                    changedRecords: changedRecords,
                    deletedRecordIDs: deletedRecordIDs,
                    newToken: cursor
                )
            }
        }
    }

    private struct PullPage {
        let result: PullResult
        let moreComing: Bool
    }

    private func performPull(since token: CKServerChangeToken?) async throws -> PullPage {
        guard let database else { throw Self.unavailable }
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = token

        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: [zoneID: configuration]
        )

        var changedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecord.ID] = []
        var newToken: CKServerChangeToken?
        var moreComing = false
        var zoneError: Error?

        return try await withCheckedThrowingContinuation { continuation in
            operation.recordWasChangedBlock = { _, result in
                if case .success(let record) = result {
                    changedRecords.append(record)
                }
            }

            operation.recordWithIDWasDeletedBlock = { recordID, _ in
                deletedRecordIDs.append(recordID)
            }

            operation.recordZoneChangeTokensUpdatedBlock = { _, serverToken, _ in
                newToken = serverToken
            }

            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let (serverToken, _, hasMore)):
                    newToken = serverToken
                    moreComing = hasMore
                case .failure(let error):
                    Self.logger.warning("Zone fetch result error: \(error.localizedDescription)")
                    zoneError = error
                }
            }

            /// The zone's own error is the specific one. CloudKit reports an expired token or a
            /// deleted zone per zone and wraps the operation in a partial failure that says only
            /// that some items failed, so the wrapper is never what decides the run.
            operation.fetchRecordZoneChangesResultBlock = { result in
                if let zoneError {
                    continuation.resume(throwing: zoneError)
                    return
                }
                switch result {
                case .success:
                    continuation.resume(returning: PullPage(
                        result: PullResult(
                            changedRecords: changedRecords,
                            deletedRecordIDs: deletedRecordIDs,
                            newToken: newToken
                        ),
                        moreComing: moreComing
                    ))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            database.add(operation)
        }
    }

    // MARK: - Retry Logic

    /// The last attempt's error is thrown as it arrives, without the wait meant for an attempt that
    /// will not come.
    private func withRetry<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch let error as CKError where isTransientError(error) && attempt < Self.maxRetries - 1 {
                let delay = retryDelay(for: error, attempt: attempt)
                Self.logger.warning(
                    "Transient CK error (attempt \(attempt + 1)/\(Self.maxRetries)): \(error.localizedDescription)"
                )
                /// A retry that waits out a rate limit has no deadline of its own, so it can
                /// ride whichever wake the system was going to make anyway.
                try await Task.sleep(for: .seconds(delay), tolerance: .seconds(delay / 2))
                attempt += 1
            }
        }
    }

    private func isTransientError(_ error: CKError) -> Bool {
        SyncRetryPolicy.isTransient(error.code)
    }

    private func retryDelay(for error: CKError, attempt: Int) -> Double {
        SyncRetryPolicy.delay(retryAfterSeconds: error.retryAfterSeconds, attempt: attempt)
    }
}
