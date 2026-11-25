//
//  CloudKitFailureMapping.swift
//  TablePro
//

import CloudKit
import Foundation
import TableProFFI

// Each CloudKit error as the engine takes it: a whole call's failure, or one record's outcome. The engine retries,
// splits and merges; nothing here does.
nonisolated enum CloudKitFailureMapping {
    static func failure(_ error: any Error) -> CloudKitFailure {
        if let failure = error as? CloudKitFailure {
            return failure
        }
        guard let error = error as? CKError else {
            return .Other(code: Int64(error is CancellationError ? CKError.Code.operationCancelled.rawValue : -1))
        }
        switch error.code {
        case .notAuthenticated:
            return .NoAccount
        case .accountTemporarilyUnavailable:
            return .AccountTemporarilyUnavailable
        case .managedAccountRestricted:
            return .Restricted
        case .changeTokenExpired:
            return .TokenExpired
        case .zoneNotFound:
            return .ZoneNotFound
        case .userDeletedZone:
            return .ZoneDeletedByUser
        case .limitExceeded:
            return .LimitExceeded
        case .quotaExceeded:
            return .QuotaExceeded
        case .networkUnavailable, .networkFailure:
            return .Network
        case .serviceUnavailable, .requestRateLimited, .zoneBusy, .serverResponseLost:
            return .Throttled(retryAfterMs: retryAfterMilliseconds(error))
        default:
            return .Other(code: Int64(error.code.rawValue))
        }
    }

    static func account(_ status: CKAccountStatus) -> CloudKitFailure? {
        switch status {
        case .available:
            return nil
        case .noAccount:
            return .NoAccount
        case .restricted:
            return .Restricted
        case .couldNotDetermine, .temporarilyUnavailable:
            return .AccountTemporarilyUnavailable
        @unknown default:
            return .AccountTemporarilyUnavailable
        }
    }

    static func saved(_ name: String, _ result: Result<CKRecord, any Error>?) -> CloudKitOutcome {
        switch result {
        case .success(let record):
            return .saved(name: name, systemFields: CloudKitRecordConversion.systemFields(of: record))
        case .failure(let error as CKError) where error.code == .serverRecordChanged:
            return .serverChanged(name: name, server: error.serverRecord.map(CloudKitRecordConversion.record))
        case .failure(let error as CKError) where error.code == .unknownItem:
            return .unknownItem(name: name)
        case .failure(let error):
            return failed(name, error)
        case nil:
            return failed(name, CKError(.internalError))
        }
    }

    static func deleted(_ name: String, _ result: Result<Void, any Error>?) -> CloudKitOutcome {
        switch result {
        case .success:
            return .deleted(name: name)
        case .failure(let error as CKError) where error.code == .unknownItem:
            return .unknownItem(name: name)
        case .failure(let error):
            return failed(name, error)
        case nil:
            return failed(name, CKError(.internalError))
        }
    }

    static func fetched(_ name: String, _ result: Result<CKRecord, any Error>?) -> CloudKitFetched {
        switch result {
        case .success(let record):
            return .found(record: CloudKitRecordConversion.record(record))
        case .failure(let error as CKError) where error.code == .unknownItem:
            return .missing(name: name)
        case .failure(let error):
            let error = error as? CKError ?? CKError(.internalError)
            return .failed(name: name, code: Int64(error.code.rawValue), retryAfterMs: retryAfterMilliseconds(error))
        case nil:
            return .failed(name: name, code: Int64(CKError.Code.internalError.rawValue), retryAfterMs: nil)
        }
    }

    // A record CloudKit was never sent, since it would have raised on it.
    static func refused(_ name: String) -> CloudKitOutcome {
        failed(name, CKError(.invalidArguments))
    }

    private static func failed(_ name: String, _ error: any Error) -> CloudKitOutcome {
        let error = error as? CKError ?? CKError(.internalError)
        return .failed(name: name, code: Int64(error.code.rawValue), retryAfterMs: retryAfterMilliseconds(error))
    }

    static func retryAfterMilliseconds(_ error: CKError) -> UInt64? {
        guard let seconds = error.retryAfterSeconds, seconds.isFinite, seconds >= 0 else { return nil }
        return UInt64(exactly: (seconds * 1_000).rounded(.up)) ?? UInt64.max
    }
}
