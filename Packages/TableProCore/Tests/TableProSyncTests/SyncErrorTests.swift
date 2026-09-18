import CloudKit
import Foundation
import Testing

import TableProSyncTransport

@Suite("Sync error classification")
struct SyncErrorTests {
    @Test("A CloudKit code maps to the matching sync error", arguments: [
        (CKError.Code.networkUnavailable, SyncError.networkUnavailable),
        (CKError.Code.networkFailure, SyncError.networkUnavailable),
        (CKError.Code.notAuthenticated, SyncError.accountUnavailable),
        (CKError.Code.quotaExceeded, SyncError.quotaExceeded),
        (CKError.Code.zoneNotFound, SyncError.zoneNotFound),
        (CKError.Code.changeTokenExpired, SyncError.tokenExpired)
    ])
    func cloudKitCodesMap(_ code: CKError.Code, _ expected: SyncError) {
        #expect(SyncError.from(CKError(code)) == expected)
    }

    @Test("An unmapped CloudKit code becomes a server error")
    func unmappedCodeBecomesServerError() {
        guard case .serverError = SyncError.from(CKError(.internalError)) else {
            Issue.record("Expected a server error")
            return
        }
    }

    @Test("A sync error passes through unchanged")
    func syncErrorPassesThrough() {
        #expect(SyncError.from(SyncError.conflictDetected) == .conflictDetected)
        #expect(SyncError.from(SyncError.tokenExpired) == .tokenExpired)
    }

    @Test("A foreign error becomes an unknown error")
    func foreignErrorBecomesUnknown() {
        struct Foreign: Error {}
        guard case .unknown = SyncError.from(Foreign()) else {
            Issue.record("Expected an unknown error")
            return
        }
    }

    @Test("Every case describes itself")
    func everyCaseHasADescription() {
        let all: [SyncError] = [
            .networkUnavailable,
            .accountUnavailable,
            .quotaExceeded,
            .zoneNotFound,
            .serverError("detail"),
            .conflictDetected,
            .encodingFailed("detail"),
            .pushRejected(count: 2, detail: "detail"),
            .tokenExpired,
            .unknown("detail")
        ]
        for error in all {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test("A rejection reports its count and detail")
    func rejectionReportsCountAndDetail() {
        let description = SyncError.pushRejected(count: 3, detail: "schema").errorDescription
        #expect(description?.contains("3") == true)
        #expect(description?.contains("schema") == true)
    }

    @Test("Rejections with different counts are not equal")
    func rejectionsCompareByPayload() {
        #expect(SyncError.pushRejected(count: 1, detail: "a") != .pushRejected(count: 2, detail: "a"))
        #expect(SyncError.pushRejected(count: 1, detail: "a") == .pushRejected(count: 1, detail: "a"))
    }
}
