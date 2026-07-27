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

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID

    public static let zoneName = "TableProSync"
    public static let defaultContainerID = "iCloud.com.TablePro"

    /// CloudKit allows at most 400 items (saves + deletions) per modify operation
    private static let maxBatchSize = 400
    private static let maxRetries = 3

    public init(containerIdentifier: String = defaultContainerID) {
        self.container = CKContainer(identifier: containerIdentifier)
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    public var currentZoneID: CKRecordZone.ID { zoneID }

    // MARK: - Account Status

    public func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    // MARK: - Zone Management

    public func ensureZoneExists() async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await database.save(zone)
        Self.logger.trace("Created or confirmed sync zone: \(Self.zoneName)")
    }

    // MARK: - Push

    public func push(records: [CKRecord], deletions: [CKRecord.ID]) async throws {
        guard !records.isEmpty || !deletions.isEmpty else { return }

        var remainingSaves = records[...]
        var remainingDeletions = deletions[...]

        while !remainingSaves.isEmpty || !remainingDeletions.isEmpty {
            let savesCount = min(remainingSaves.count, Self.maxBatchSize)
            let batchSaves = Array(remainingSaves.prefix(savesCount))
            remainingSaves = remainingSaves.dropFirst(savesCount)

            let deletionsCount = min(remainingDeletions.count, Self.maxBatchSize - savesCount)
            let batchDeletions = Array(remainingDeletions.prefix(deletionsCount))
            remainingDeletions = remainingDeletions.dropFirst(deletionsCount)

            try await pushBatch(records: batchSaves, deletions: batchDeletions)
        }

        Self.logger.info("Pushed \(records.count) records, \(deletions.count) deletions")
    }

    private func pushBatch(records: [CKRecord], deletions: [CKRecord.ID]) async throws {
        try await withRetry {
            let operation = CKModifyRecordsOperation(
                recordsToSave: records,
                recordIDsToDelete: deletions
            )
            // .changedKeys overwrites only the fields we set, safe for partial updates
            operation.savePolicy = .changedKeys
            operation.isAtomic = true

            return try await withCheckedThrowingContinuation { continuation in
                operation.perRecordSaveBlock = { recordID, result in
                    if case .failure(let error) = result {
                        Self.logger.error(
                            "Failed to save record \(recordID.recordName): \(error.localizedDescription)"
                        )
                    }
                }

                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                self.database.add(operation)
            }
        }
    }

    // MARK: - Pull

    public func pull(since token: CKServerChangeToken?) async throws -> PullResult {
        try await withRetry {
            try await performPull(since: token)
        }
    }

    private func performPull(since token: CKServerChangeToken?) async throws -> PullResult {
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = token

        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID],
            configurationsByRecordZoneID: [zoneID: configuration]
        )

        var changedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecord.ID] = []
        var newToken: CKServerChangeToken?

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
                case .success(let (serverToken, _, _)):
                    newToken = serverToken
                case .failure(let error):
                    Self.logger.warning("Zone fetch result error: \(error.localizedDescription)")
                    // Zone-level failure with records collected so far is acceptable —
                    // newToken stays nil, forcing a full re-fetch on next sync cycle.
                }
            }

            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: PullResult(
                        changedRecords: changedRecords,
                        deletedRecordIDs: deletedRecordIDs,
                        newToken: newToken
                    ))
                case .failure(let error):
                    // Map CKError.changeTokenExpired to SyncError.tokenExpired
                    if let ckError = error as? CKError, ckError.code == .changeTokenExpired {
                        continuation.resume(throwing: SyncError.tokenExpired)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }

            database.add(operation)
        }
    }

    // MARK: - Retry Logic

    private func withRetry<T>(_ operation: () async throws -> T) async throws -> T {
        var lastError: Error?

        for attempt in 0..<Self.maxRetries {
            do {
                return try await operation()
            } catch let error as CKError where isTransientError(error) {
                lastError = error
                let delay = retryDelay(for: error, attempt: attempt)
                Self.logger.warning(
                    "Transient CK error (attempt \(attempt + 1)/\(Self.maxRetries)): \(error.localizedDescription)"
                )
                try await Task.sleep(for: .seconds(delay))
            } catch {
                throw error
            }
        }

        throw lastError ?? SyncError.unknownError("Max retries exceeded")
    }

    private func isTransientError(_ error: CKError) -> Bool {
        switch error.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy:
            return true
        default:
            return false
        }
    }

    private func retryDelay(for error: CKError, attempt: Int) -> Double {
        if let suggestedDelay = error.retryAfterSeconds {
            return suggestedDelay
        }
        return Double(1 << attempt)
    }
}
