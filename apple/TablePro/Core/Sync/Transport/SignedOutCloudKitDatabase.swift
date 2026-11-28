//
//  SignedOutCloudKitDatabase.swift
//  TablePro
//

import CloudKit
import Foundation
import TableProSyncTransport

// CloudKit as a Mac signed out of iCloud sees it: a Debug device profile shares the Mac's iCloud account with the real
// store, so its engine never reaches the person's zone. No container is made.
nonisolated struct SignedOutCloudKitDatabase: CloudKitDatabase {
    func accountStatus() async throws -> CKAccountStatus {
        .noAccount
    }

    func userRecordName() async throws -> String {
        throw Self.signedOut
    }

    func saveZone(_ zone: CKRecordZone.ID) async throws {
        throw Self.signedOut
    }

    func deleteZone(_ zone: CKRecordZone.ID) async throws {
        throw Self.signedOut
    }

    func saveSubscription(_ subscription: CKSubscription) async throws {
        throw Self.signedOut
    }

    func fetchChanges(in zone: CKRecordZone.ID, since token: CKServerChangeToken?) async throws -> CloudKitChangesPage {
        throw Self.signedOut
    }

    func fetchRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        throw Self.signedOut
    }

    func modifyRecords(saving records: [CKRecord], deleting ids: [CKRecord.ID]) async throws -> CloudKitModifyResults {
        throw Self.signedOut
    }

    private static let signedOut = CKError(.notAuthenticated)
}
