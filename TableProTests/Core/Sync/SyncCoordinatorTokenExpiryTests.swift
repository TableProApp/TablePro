//
//  SyncCoordinatorTokenExpiryTests.swift
//  TableProTests
//

import CloudKit
import Foundation
import TableProSyncTransport
@testable import TablePro
import Testing

@Suite("Sync coordinator token expiry")
struct SyncCoordinatorTokenExpiryTests {
    @Test("The expired token thrown by the engine is recognised")
    func recognisesTheEngineError() {
        #expect(SyncCoordinator.isTokenExpired(SyncError.tokenExpired))
    }

    @Test("A raw CloudKit expiry is not recognised because the engine never rethrows it")
    func doesNotMatchRawCloudKitError() {
        #expect(!SyncCoordinator.isTokenExpired(CKError(.changeTokenExpired)))
    }

    @Test("Any other sync error is not treated as an expired token")
    func otherSyncErrorsAreNotTokenExpiry() {
        #expect(!SyncCoordinator.isTokenExpired(SyncError.networkUnavailable))
        #expect(!SyncCoordinator.isTokenExpired(SyncError.accountUnavailable))
        #expect(!SyncCoordinator.isTokenExpired(SyncError.zoneNotFound))
    }

    @Test("A foreign error is not treated as an expired token")
    func foreignErrorsAreNotTokenExpiry() {
        struct Foreign: Error {}
        #expect(!SyncCoordinator.isTokenExpired(Foreign()))
    }

    @Test("A CloudKit expiry still classifies as expired when mapped through SyncError")
    func cloudKitExpiryClassifiesThroughMapping() {
        #expect(SyncCoordinator.isTokenExpired(SyncError.from(CKError(.changeTokenExpired))))
    }
}
