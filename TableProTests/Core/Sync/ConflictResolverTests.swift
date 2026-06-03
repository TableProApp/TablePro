//
//  ConflictResolverTests.swift
//  TableProTests
//

import CloudKit
import Foundation
import Testing

@testable import TablePro

@Suite("ConflictResolver", .serialized)
@MainActor
struct ConflictResolverTests {
    private let resolver = ConflictResolver.shared

    init() {
        while resolver.hasConflicts {
            _ = resolver.resolveCurrentConflict(keepLocal: false)
        }
    }

    private func makeConflict(local: [String: String], server: [String: String]) -> SyncConflict {
        let localRecord = CKRecord(recordType: "Connection")
        for (key, value) in local {
            localRecord[key] = value as CKRecordValue
        }
        let serverRecord = CKRecord(recordType: "Connection")
        for (key, value) in server {
            serverRecord[key] = value as CKRecordValue
        }
        return SyncConflict(
            recordType: .connection,
            entityName: "users",
            localRecord: localRecord,
            serverRecord: serverRecord,
            localModifiedAt: Date(timeIntervalSince1970: 100),
            serverModifiedAt: Date(timeIntervalSince1970: 200)
        )
    }

    @Test("addConflict queues the conflict as current")
    func addConflictQueues() {
        #expect(!resolver.hasConflicts)
        resolver.addConflict(makeConflict(local: ["name": "L"], server: ["name": "S"]))

        #expect(resolver.hasConflicts)
        #expect(resolver.currentConflict?.entityName == "users")

        _ = resolver.resolveCurrentConflict(keepLocal: false)
    }

    @Test("Keeping the server version discards the conflict and returns nil")
    func keepServerReturnsNil() {
        resolver.addConflict(makeConflict(local: ["name": "L"], server: ["name": "S"]))

        let result = resolver.resolveCurrentConflict(keepLocal: false)

        #expect(result == nil)
        #expect(!resolver.hasConflicts)
    }

    @Test("Keeping local copies local field values onto the server record")
    func keepLocalCopiesFieldsOntoServerRecord() {
        resolver.addConflict(makeConflict(local: ["name": "Local"], server: ["name": "Server"]))

        let resolved = resolver.resolveCurrentConflict(keepLocal: true)

        #expect(resolved?["name"] as? String == "Local")
        #expect(!resolver.hasConflicts)
    }

    @Test("Conflicts are resolved in FIFO order")
    func conflictsResolveInFifoOrder() {
        resolver.addConflict(makeConflict(local: ["name": "first"], server: ["name": "s1"]))
        resolver.addConflict(makeConflict(local: ["name": "second"], server: ["name": "s2"]))

        #expect(resolver.currentConflict?.localRecord["name"] as? String == "first")
        _ = resolver.resolveCurrentConflict(keepLocal: false)
        #expect(resolver.currentConflict?.localRecord["name"] as? String == "second")
        _ = resolver.resolveCurrentConflict(keepLocal: false)
        #expect(!resolver.hasConflicts)
    }

    @Test("Resolving with no pending conflicts returns nil")
    func resolveWithNoConflictsReturnsNil() {
        #expect(resolver.resolveCurrentConflict(keepLocal: false) == nil)
    }
}
