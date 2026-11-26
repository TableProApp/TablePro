//
//  CloudKitCoreTransport.swift
//  TablePro
//

import CloudKit
import Foundation
import os
import TableProFFI
import TableProSyncTransport

// The core engine's CloudKit transport (core ADR 0054, The CloudKit transport): one CloudKit operation per call, each
// bound to the iCloud account the engine names. It maps what CloudKit answers and decides nothing.
//
// - A call reads the signed-in account before its operation and again after it, and fails with `AccountChanged` when
//   either is not the one it was given. A create and a deletion name the zone with that account as its owner, so
//   CloudKit itself refuses them under another account.
// - The engine stopping a pass drops the call's future, which cancels the task and with it the operation.
// - It starts closed and is open only while iCloud runs on this Mac. Closing it, as when a configuration profile leaves
//   iCloud out, cancels every call in flight, and none starts until it opens.
nonisolated final class CloudKitCoreTransport: CloudKitTransport, @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CloudKitCoreTransport")

    private let database: any CloudKitDatabase
    private let gate = CloudKitTransportGate()
    private let confirmed = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(database: any CloudKitDatabase = LiveCloudKitDatabase()) {
        self.database = database
    }

    static func zone(of account: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: CloudKitSyncEngine.zoneName, ownerName: account)
    }

    // MARK: - The engine's calls

    func accountStatus() async throws -> CloudKitAccount {
        try await gate.run { [database] in
            let status = try await database.accountStatus()
            if let failure = CloudKitFailureMapping.account(status) {
                throw failure
            }
            let name = try await database.userRecordName()
            return CloudKitAccount(userRecordName: name)
        }
    }

    func ensureZone(account: String) async throws {
        try await bound(to: account) { [database] zone in
            try await database.saveZone(zone)
        }
    }

    func deleteZone(account: String) async throws {
        try await bound(to: account) { [database] zone in
            try await database.deleteZone(zone)
        }
    }

    func fetchChanges(account: String, token: Data?) async throws -> CloudKitChanges {
        // A token this build cannot read is as good as expired: the engine starts a full fetch.
        let previous: CKServerChangeToken?
        if let token {
            guard let unarchived = CloudKitChangeToken.unarchive(token) else { throw CloudKitFailure.TokenExpired }
            previous = unarchived
        } else {
            previous = nil
        }
        return try await bound(to: account) { [database] zone in
            let page = try await database.fetchChanges(in: zone, since: previous)
            return CloudKitChanges(
                changed: page.changed.map(CloudKitRecordConversion.record),
                deleted: page.deleted.map { CloudKitDeletion(name: $0.id.recordName, recordType: $0.recordType) },
                unfetched: page.unread.map(\.recordName),
                // A page that moved no position hands back the one it started from.
                token: page.token.flatMap(CloudKitChangeToken.archive) ?? token ?? Data(),
                more: page.moreComing
            )
        }
    }

    func fetchRecords(account: String, names: [String]) async throws -> [CloudKitFetched] {
        try await bound(to: account) { [database] zone in
            let ids = names.map { CloudKitRecordID.make(name: $0, in: zone) }
            let results = Self.byName(try await database.fetchRecords(ids.compactMap { $0 }))
            return zip(names, ids).map { name, id in
                guard id != nil else {
                    return .failed(name: name, code: Int64(CKError.Code.invalidArguments.rawValue), retryAfterMs: nil)
                }
                return CloudKitFailureMapping.fetched(name, results[name])
            }
        }
    }

    func modify(account: String, saves: [CloudKitRecord], deletes: [String]) async throws -> [CloudKitOutcome] {
        try await bound(to: account) { [database] zone in
            // CloudKit raises on a name saved twice, deleted twice, or saved and deleted in one operation, so a name
            // after its first appearance is refused.
            var seen: Set<String> = []
            let records = saves.map { save -> CKRecord? in
                guard seen.insert(save.name).inserted else { return nil }
                return try? CloudKitRecordConversion.ckRecord(save, in: zone)
            }
            let ids = deletes.map { name -> CKRecord.ID? in
                guard seen.insert(name).inserted else { return nil }
                return CloudKitRecordID.make(name: name, in: zone)
            }
            let sending = records.compactMap { $0 }
            let deleting = ids.compactMap { $0 }
            var results = CloudKitModifyResults()
            if !sending.isEmpty || !deleting.isEmpty {
                results = try await database.modifyRecords(saving: sending, deleting: deleting)
            }
            let saved = Self.byName(results.saved)
            let removed = Self.byName(results.deleted)
            let savedOutcomes = zip(saves, records).map { save, record in
                record == nil ? CloudKitFailureMapping.refused(save.name) : CloudKitFailureMapping.saved(save.name, saved[save.name])
            }
            let deletedOutcomes = zip(deletes, ids).map { name, id in
                id == nil ? CloudKitFailureMapping.refused(name) : CloudKitFailureMapping.deleted(name, removed[name])
            }
            return savedOutcomes + deletedOutcomes
        }
    }

    // MARK: - The app's calls

    // Subscriptions stay in Swift. The account is the one the engine's last call was bound to and found signed in.
    var confirmedAccount: String? {
        confirmed.withLock { $0 }
    }

    // CloudKit's own error comes back, so `SyncPushChannel` tells a build's fault from a passing one.
    func saveSubscription(account: String) async throws {
        try await bound(to: account, mapsFailures: false) { [database] _ in
            try await database.saveSubscription(SyncPushSubscription.make())
        }
    }

    // `CKAccountChanged`: what is in flight belongs to the account that was signed in, and fails as such.
    func cancelCallsInFlight() {
        gate.cancelForAccountChange()
    }

    func close() {
        gate.close()
    }

    func open() {
        gate.open()
    }

    var isClosed: Bool {
        gate.isClosed
    }

    // MARK: - Binding to the account

    // CloudKit answers with the IDs it holds, whose owner may read as the current user's placeholder rather than the
    // account's name, so each answer is found by its record name.
    private static func byName<Value>(_ results: [CKRecord.ID: Value]) -> [String: Value] {
        Dictionary(results.map { ($0.key.recordName, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private func bound<Value: Sendable>(
        to account: String,
        mapsFailures: Bool = true,
        _ operation: @escaping @Sendable (CKRecordZone.ID) async throws -> Value
    ) async throws -> Value {
        try await gate.run(mapsFailures: mapsFailures) { [self] in
            try await confirm(account)
            let result: Result<Value, any Error>
            do {
                result = .success(try await operation(Self.zone(of: account)))
            } catch {
                result = .failure(error)
            }
            try Task.checkCancellation()
            // A reply for another account is that account's, whatever it says.
            try await confirm(account)
            return try result.get()
        }
    }

    private func confirm(_ account: String) async throws {
        let signedIn = try await database.userRecordName()
        guard signedIn == account else {
            Self.logger.notice("The iCloud account changed around a call, so its results are discarded")
            throw CloudKitFailure.AccountChanged
        }
        confirmed.withLock { $0 = account }
    }
}

// Each call runs as a task of its own, so closing the gate or an account change can cancel it from outside the call.
nonisolated final class CloudKitTransportGate: Sendable {
    private struct State {
        var isClosed = true
        var calls: [UUID: @Sendable () -> Void] = [:]
        // Bumped by an account change, so a call it cancelled fails as `AccountChanged`.
        var accountChanges = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isClosed: Bool {
        state.withLock { $0.isClosed }
    }

    func run<Value: Sendable>(
        mapsFailures: Bool = true,
        _ body: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let id = UUID()
        let admitted = state.withLock { state -> (Task<Value, any Error>, Int)? in
            guard !state.isClosed else { return nil }
            let call = Task { try await body() }
            state.calls[id] = { call.cancel() }
            return (call, state.accountChanges)
        }
        guard let (call, accountChanges) = admitted else {
            throw CloudKitFailure.Other(code: Int64(CKError.Code.operationCancelled.rawValue))
        }
        defer { _ = state.withLock { $0.calls.removeValue(forKey: id) } }
        do {
            return try await withTaskCancellationHandler {
                try await call.value
            } onCancel: {
                call.cancel()
            }
        } catch {
            if state.withLock({ $0.accountChanges }) != accountChanges {
                throw CloudKitFailure.AccountChanged
            }
            throw mapsFailures ? CloudKitFailureMapping.failure(error) : error
        }
    }

    func cancelForAccountChange() {
        let calls = state.withLock { state -> [@Sendable () -> Void] in
            state.accountChanges += 1
            return Array(state.calls.values)
        }
        for cancel in calls {
            cancel()
        }
    }

    func close() {
        let calls = state.withLock { state -> [@Sendable () -> Void] in
            state.isClosed = true
            return Array(state.calls.values)
        }
        for cancel in calls {
            cancel()
        }
    }

    func open() {
        state.withLock { $0.isClosed = false }
    }
}
