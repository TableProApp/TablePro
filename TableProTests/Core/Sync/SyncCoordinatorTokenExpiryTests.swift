//
//  SyncCoordinatorTokenExpiryTests.swift
//  TableProTests
//

import CloudKit
import Foundation
import TableProSyncTransport
@testable import TablePro
import Testing

struct SyncCoordinatorTokenExpiryTests {
    /// The engine rethrows CloudKit's own per-zone error now, which arrives inside a partial failure
    /// on a zone fetch; matching only a top-level code missed it and every delta pull failed for good.
    @Test("A CloudKit expiry is recognised, bare or inside a partial failure")
    func recognisesCloudKitExpiry() {
        let zoneID = CKRecordZone.ID(zoneName: "TableProSync", ownerName: CKCurrentUserDefaultName)
        let partial = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [zoneID: CKError(.changeTokenExpired)]
        ])

        #expect(SyncCoordinator.isTokenExpired(CKError(.changeTokenExpired)))
        #expect(SyncCoordinator.isTokenExpired(partial))
    }

    @Test("Any other CloudKit error is not treated as an expired token")
    func otherErrorsAreNotTokenExpiry() {
        #expect(!SyncCoordinator.isTokenExpired(CKError(.networkUnavailable)))
        #expect(!SyncCoordinator.isTokenExpired(CKError(.notAuthenticated)))
        #expect(!SyncCoordinator.isTokenExpired(CKError(.zoneNotFound)))
    }

    @Test("A foreign error is not treated as an expired token")
    func foreignErrorsAreNotTokenExpiry() {
        struct Foreign: Error {}
        #expect(!SyncCoordinator.isTokenExpired(Foreign()))
    }
}
