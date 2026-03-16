//
//  CloudKitSyncEngine.swift
//  TablePro
//
//  Actor wrapping all CloudKit operations: zone setup, push, pull
//

import CloudKit
import Foundation
import os

/// Result of a pull operation
struct PullResult: Sendable {
    let changedRecords: [CKRecord]
    let deletedRecordIDs: [CKRecord.ID]
    let newToken: CKServerChangeToken?
}

/// Actor that serializes all CloudKit I/O
actor CloudKitSyncEngine {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CloudKitSyncEngine")

    private let container: CKContainer
    private let database: CKDatabase
    let zoneID: CKRecordZone.ID

    private static let containerIdentifier = "iCloud.com.TablePro"
    private static let zoneName = "TableProSync"
    private static let maxRetries = 3

    init() {
        container = CKContainer(identifier: Self.containerIdentifier)
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    // MARK: - Account Status

    func checkAccountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    // MARK: - Zone Management

    func ensureZoneExists() async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await database.save(zone)
        Self.logger.trace("Created or confirmed sync zone: \(Self.zoneName)")
    }

    // MARK: - Push

    /// CloudKit allows at most 400 items (saves + deletions) per modify operation
    private static let maxBatchSize = 400

    func push(records: [CKRecord], deletions: [CKRecord.ID]) async throws {
        guard !records.isEmpty || !deletions.isEmpty else { return }

        // Split into batches that fit within CloudKit's 400-item limit
        var remainingSaves = records[...]
        var remainingDeletions = deletions[...]

        while !remainingSaves.isEmpty || !remainingDeletions.isEmpty {
            let batchSaves: [CKRecord]
            let batchDeletions: [CKRecord.ID]

            let savesCount = min(remainingSaves.count, Self.maxBatchSize)
            batchSaves = Array(remainingSaves.prefix(savesCount))
            remainingSaves = remainingSaves.dropFirst(savesCount)

            let deletionsCount = min(remainingDeletions.count, Self.maxBatchSize - savesCount)
            batchDeletions = Array(remainingDeletions.prefix(deletionsCount))
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
            // Use .changedKeys so we don't need to track server change tags
            // This overwrites only the fields we set, which is safe for our use case
            operation.savePolicy = .changedKeys
            operation.isAtomic = false

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

    func pull(since token: CKServerChangeToken?) async throws -> PullResult {
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
                }
            }

            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    let pullResult = PullResult(
                        changedRecords: changedRecords,
                        deletedRecordIDs: deletedRecordIDs,
                        newToken: newToken
                    )
                    continuation.resume(returning: pullResult)
                case .failure(let error):
                    continuation.resume(throwing: error)
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

        throw lastError ?? SyncError.unknown("Max retries exceeded")
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
        return Double(1 << attempt) // Exponential backoff: 1, 2, 4 seconds
    }
}
