import CloudKit
import Foundation
@testable import TablePro
import TableProFFI
import TableProSyncTransport
import TableProTestSupport
import Testing

struct CloudKitCoreTransportTests {
    private let database = FakeCloudKitDatabase()
    private let transport: CloudKitCoreTransport
    private static let zone = CloudKitCoreTransport.zone(of: "_alice")

    init() {
        transport = CloudKitCoreTransport(database: database)
        transport.open()
    }

    private static func tag(_ name: String, systemFields: Data? = nil, fields: [CloudKitField] = []) -> CloudKitRecord {
        CloudKitRecord(recordType: "ConnectionTag", name: name, systemFields: systemFields, createdMs: nil, fields: fields)
    }

    private static func serverRecord(_ name: String, in zone: CKRecordZone.ID = zone) -> CKRecord {
        let record = CKRecord(recordType: "ConnectionTag", recordID: CKRecord.ID(recordName: name, zoneID: zone))
        record["name"] = "Production"
        return record
    }

    private func failure(of call: () async throws -> Void) async -> CloudKitFailure? {
        do {
            try await call()
            return nil
        } catch let failure as CloudKitFailure {
            return failure
        } catch {
            Issue.record("not a CloudKitFailure: \(error)")
            return nil
        }
    }

    // MARK: - The account

    @Test("The account status names the signed-in user, and each other state is its own failure")
    func accountStatus() async throws {
        #expect(try await transport.accountStatus().userRecordName == "_alice")
        for (status, expected) in [
            (CKAccountStatus.noAccount, CloudKitFailure.NoAccount),
            (.restricted, .Restricted),
            (.temporarilyUnavailable, .AccountTemporarilyUnavailable),
            (.couldNotDetermine, .AccountTemporarilyUnavailable)
        ] {
            database.update { $0.status = status }
            #expect(await failure { _ = try await transport.accountStatus() } == expected)
        }
    }

    @Test("A call for another account than the one signed in reaches no operation")
    func otherAccountBeforeTheCall() async throws {
        let outcome = await failure {
            _ = try await transport.modify(account: "_bob", saves: [Self.tag("Tag_A")], deletes: [])
        }

        #expect(outcome == .AccountChanged)
        #expect(database.modifyStarted == 0)
    }

    @Test("An account switch during a call discards what the call brought back")
    func accountSwitchDuringTheCall() async throws {
        database.update { $0.signedInAfterOperation = "_bob" }

        let outcome = await failure {
            _ = try await transport.modify(account: "_alice", saves: [Self.tag("Tag_A")], deletes: [])
        }

        #expect(outcome == .AccountChanged)
        #expect(database.modifyStarted == 1)
    }

    @Test("A zone is created and deleted under the account as its owner, not the current user's placeholder")
    func zoneOwnedByTheAccount() async throws {
        try await transport.ensureZone(account: "_alice")
        try await transport.deleteZone(account: "_alice")

        let expected = CKRecordZone.ID(zoneName: CloudKitSyncEngine.zoneName, ownerName: "_alice")
        #expect(database.read { $0.savedZones } == [expected])
        #expect(database.read { $0.deletedZones } == [expected])
    }

    // MARK: - Saves and deletions

    @Test("A create goes into the account's zone with the fields named, and comes back with its system fields")
    func createRoundTrip() async throws {
        let outcomes = try await transport.modify(
            account: "_alice",
            saves: [Self.tag("Tag_A", fields: [
                CloudKitField(name: "name", value: .text(value: "Production")),
                CloudKitField(name: "sortOrder", value: .int64(value: 3))
            ])],
            deletes: []
        )

        let sent = try #require(database.read { $0.modifyCalls.first?.saves.first })
        #expect(sent.recordID.zoneID == Self.zone)
        #expect(sent["name"] as? String == "Production")
        #expect(sent["sortOrder"] as? Int64 == 3)
        guard case .saved(let name, let systemFields) = try #require(outcomes.first) else {
            Issue.record("not saved: \(outcomes)")
            return
        }
        #expect(name == "Tag_A")
        let rebuilt = try #require(CloudKitRecordConversion.rebuild(systemFields))
        #expect(rebuilt.recordID == sent.recordID)
        #expect(rebuilt.recordType == "ConnectionTag")
    }

    @Test("System fields of a record never saved make a create in the account's zone, whatever zone they name")
    func neverSavedSystemFieldsCreateInTheBoundZone() async throws {
        let elsewhere = CKRecordZone.ID(zoneName: CloudKitSyncEngine.zoneName, ownerName: "_mallory")
        let systemFields = CloudKitRecordConversion.systemFields(of: Self.serverRecord("Tag_A", in: elsewhere))

        _ = try await transport.modify(
            account: "_alice",
            saves: [Self.tag("Tag_A", systemFields: systemFields, fields: [
                CloudKitField(name: "sortOrder", value: .int64(value: 9))
            ])],
            deletes: []
        )

        let sent = try #require(database.read { $0.modifyCalls.first?.saves.first })
        #expect(sent.recordID == CKRecord.ID(recordName: "Tag_A", zoneID: Self.zone))
        #expect(sent["sortOrder"] as? Int64 == 9)
        #expect(sent["name"] == nil)
    }

    @Test("A name saved twice, deleted twice, or saved and deleted is refused after its first appearance")
    func repeatedNamesAreRefused() async throws {
        let outcomes = try await transport.modify(
            account: "_alice",
            saves: [Self.tag("Tag_A"), Self.tag("Tag_A")],
            deletes: ["Tag_A", "Tag_B", "Tag_B"]
        )

        let refused = CloudKitOutcome.failed
        let invalid = Int64(CKError.Code.invalidArguments.rawValue)
        #expect(outcomes[1] == refused("Tag_A", invalid, nil))
        #expect(outcomes[2] == refused("Tag_A", invalid, nil))
        #expect(outcomes[3] == .deleted(name: "Tag_B"))
        #expect(outcomes[4] == refused("Tag_B", invalid, nil))
        let call = try #require(database.read { $0.modifyCalls.first })
        #expect(call.saves.map(\.recordID.recordName) == ["Tag_A"])
        #expect(call.deletes.map(\.recordName) == ["Tag_B"])
    }

    @Test("A field name CloudKit reserves is refused, not set")
    func reservedFieldNamesAreRefused() async throws {
        for name in ["recordID", "recordType", "creationDate", "modificationDate", "recordChangeTag"] {
            let outcomes = try await transport.modify(
                account: "_alice",
                saves: [Self.tag("Tag_A", fields: [CloudKitField(name: name, value: .text(value: "x"))])],
                deletes: []
            )
            #expect(outcomes == [.failed(name: "Tag_A", code: Int64(CKError.Code.invalidArguments.rawValue), retryAfterMs: nil)])
        }
        #expect(database.modifyStarted == 0)
    }

    @Test("An answer is found by record name, whatever owner CloudKit puts in its ID")
    func answersMatchByName() async throws {
        let placeholder = CKRecordZone.ID(zoneName: CloudKitSyncEngine.zoneName, ownerName: CKCurrentUserDefaultName)
        database.update { $0.records["Tag_A"] = Self.serverRecord("Tag_A", in: placeholder) }

        let fetched = try await transport.fetchRecords(account: "_alice", names: ["Tag_A"])

        guard case .found(let record) = try #require(fetched.first) else {
            Issue.record("not found: \(fetched)")
            return
        }
        #expect(record.name == "Tag_A")
    }

    @Test("Each record's answer is its own outcome: the server's copy on a conflict, unknown items, failures")
    func perRecordOutcomes() async throws {
        let server = Self.serverRecord("Tag_B")
        database.update { state in
            state.saveResults = [
                "Tag_B": CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server]),
                "Tag_C": CKError(.unknownItem),
                "Tag_D": CKError(.quotaExceeded, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 1.5)])
            ]
            state.deleteResults = ["Tag_F": CKError(.unknownItem)]
        }

        let outcomes = try await transport.modify(
            account: "_alice",
            saves: ["Tag_A", "Tag_B", "Tag_C", "Tag_D"].map { Self.tag($0) },
            deletes: ["Tag_E", "Tag_F"]
        )

        #expect(outcomes.count == 6)
        #expect(outcomes[2] == .unknownItem(name: "Tag_C"))
        #expect(outcomes[3] == .failed(
            name: "Tag_D",
            code: Int64(CKError.Code.quotaExceeded.rawValue),
            retryAfterMs: 1_500
        ))
        #expect(outcomes[4] == .deleted(name: "Tag_E"))
        #expect(outcomes[5] == .unknownItem(name: "Tag_F"))
        guard case .serverChanged(let name, let copy) = outcomes[1] else {
            Issue.record("not a conflict: \(outcomes[1])")
            return
        }
        #expect(name == "Tag_B")
        #expect(copy?.fields == [CloudKitField(name: "name", value: .text(value: "Production"))])
        #expect(copy?.systemFields != nil)
    }

    @Test("A name or field CloudKit would raise on is refused alone, and the rest of the batch still goes")
    func invalidNamesAreRefusedNotRaised() async throws {
        let tooLong = String(repeating: "x", count: SyncRecordName.maximumLength + 1)

        let outcomes = try await transport.modify(
            account: "_alice",
            saves: [
                Self.tag(tooLong),
                Self.tag("Tag_A", fields: [CloudKitField(name: "_secret", value: .text(value: "x"))]),
                CloudKitRecord(recordType: "Not a type", name: "Tag_B", systemFields: nil, createdMs: nil, fields: []),
                Self.tag("Tag_C")
            ],
            deletes: [""]
        )

        let refused = CloudKitOutcome.failed
        let invalid = Int64(CKError.Code.invalidArguments.rawValue)
        #expect(outcomes[0] == refused(tooLong, invalid, nil))
        #expect(outcomes[1] == refused("Tag_A", invalid, nil))
        #expect(outcomes[2] == refused("Tag_B", invalid, nil))
        #expect(outcomes[4] == refused("", invalid, nil))
        #expect(database.read { $0.modifyCalls.map { $0.saves.map(\.recordID.recordName) } } == [["Tag_C"]])
    }

    @Test("System fields that name another record are refused, not sent over it")
    func mismatchedSystemFieldsAreRefused() async throws {
        let other = CloudKitRecordConversion.systemFields(of: Self.serverRecord("Tag_Z"))

        let outcomes = try await transport.modify(
            account: "_alice",
            saves: [Self.tag("Tag_A", systemFields: other)],
            deletes: []
        )

        #expect(outcomes == [.failed(name: "Tag_A", code: Int64(CKError.Code.invalidArguments.rawValue), retryAfterMs: nil)])
        #expect(database.modifyStarted == 0)
    }

    // MARK: - Whole-call failures

    @Test("A whole call's CloudKit error becomes the failure the engine backs off or recovers from")
    func wholeCallFailures() async throws {
        for (error, expected) in [
            (CKError(.networkUnavailable), CloudKitFailure.Network),
            (CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: NSNumber(value: 2.5)]), .Throttled(retryAfterMs: 2_500)),
            (CKError(.zoneBusy), .Throttled(retryAfterMs: nil)),
            (CKError(.limitExceeded), .LimitExceeded),
            (CKError(.changeTokenExpired), .TokenExpired),
            (CKError(.userDeletedZone), .ZoneDeletedByUser),
            (CKError(.zoneNotFound), .ZoneNotFound),
            (CKError(.quotaExceeded), .QuotaExceeded),
            (CKError(.notAuthenticated), .NoAccount),
            (CKError(.incompatibleVersion), .Other(code: Int64(CKError.Code.incompatibleVersion.rawValue)))
        ] {
            database.update { $0.failure = error }
            #expect(await failure { _ = try await transport.fetchChanges(account: "_alice", token: nil) } == expected)
        }
    }

    // MARK: - Pulls

    @Test("A page carries the changed records, deletions with their type, unread names and whether more remain")
    func fetchChangesPage() async throws {
        let changed = Self.serverRecord("Tag_A")
        database.update { state in
            state.page = CloudKitChangesPage(
                changed: [changed],
                unread: [CKRecord.ID(recordName: "Tag_B", zoneID: Self.zone)],
                deleted: [CloudKitDeletedRecord(id: CKRecord.ID(recordName: "Tag_C", zoneID: Self.zone), recordType: "ConnectionTag")],
                moreComing: true
            )
        }

        let changes = try await transport.fetchChanges(account: "_alice", token: nil)

        #expect(changes.changed.map(\.name) == ["Tag_A"])
        #expect(changes.changed.first?.fields == [CloudKitField(name: "name", value: .text(value: "Production"))])
        #expect(changes.deleted == [CloudKitDeletion(name: "Tag_C", recordType: "ConnectionTag")])
        #expect(changes.unfetched == ["Tag_B"])
        #expect(changes.more)
        #expect(database.read { $0.fetchTokens.count } == 1)
    }

    @Test("A page's token goes to the engine in the archived form, and comes back as CloudKit's token")
    func tokenRoundTrip() async throws {
        let token = try Self.changeToken()
        database.update { $0.page = CloudKitChangesPage(token: token) }

        let first = try await transport.fetchChanges(account: "_alice", token: nil)
        _ = try await transport.fetchChanges(account: "_alice", token: first.token)

        let passed = database.read { $0.fetchTokens.last ?? nil }
        #expect(first.token == CloudKitChangeToken.archive(token))
        #expect(database.read { $0.fetchTokens.count } == 2)
        #expect(passed.flatMap(CloudKitChangeToken.archive) == first.token)
    }

    @Test("A page that moved no position hands back the token it started from")
    func pageWithoutTokenKeepsThePosition() async throws {
        let token = try #require(CloudKitChangeToken.archive(try Self.changeToken()))

        let changes = try await transport.fetchChanges(account: "_alice", token: token)

        #expect(changes.token == token)
    }

    @Test("A token this build cannot read is expired, and asks CloudKit nothing")
    func unreadableTokenIsExpired() async throws {
        let outcome = await failure {
            _ = try await transport.fetchChanges(account: "_alice", token: Data("not a token".utf8))
        }

        #expect(outcome == .TokenExpired)
        #expect(database.read { $0.fetchTokens.isEmpty })
    }

    @Test("A fetch by name answers each name: found, missing or failed")
    func fetchRecordsByName() async throws {
        database.update { state in
            state.records["Tag_A"] = Self.serverRecord("Tag_A")
            state.fetchResults["Tag_C"] = CKError(.serviceUnavailable)
        }

        let fetched = try await transport.fetchRecords(account: "_alice", names: ["Tag_A", "Tag_B", "Tag_C"])

        guard case .found(let record) = fetched[0] else {
            Issue.record("not found: \(fetched[0])")
            return
        }
        #expect(record.name == "Tag_A")
        #expect(fetched[1] == .missing(name: "Tag_B"))
        #expect(fetched[2] == .failed(name: "Tag_C", code: Int64(CKError.Code.serviceUnavailable.rawValue), retryAfterMs: nil))
    }

    // MARK: - Values

    @Test("Values cross as CloudKit's own types and come back the same")
    func valuesRoundTrip() throws {
        let values: [CloudKitValue] = [
            .text(value: "a"),
            .int64(value: 42),
            .double(value: 1.25),
            .timestamp(value: 1_764_000_000_123),
            .bytes(value: Data([1, 2, 3])),
            .textList(value: ["a", "b"])
        ]
        for value in values {
            #expect(CloudKitRecordConversion.value(CloudKitRecordConversion.ckValue(value)) == value)
        }
    }

    // MARK: - Stopping (P1-I3)

    @Test("The transport starts closed: nothing reaches CloudKit until iCloud runs")
    func startsClosed() async throws {
        let closed = CloudKitCoreTransport(database: database)

        let outcome = await failure {
            _ = try await closed.modify(account: "_alice", saves: [Self.tag("Tag_A")], deletes: [])
        }

        #expect(outcome == .Other(code: Int64(CKError.Code.operationCancelled.rawValue)))
        #expect(database.read { $0.userRecordReads } == 0)
        #expect(database.modifyStarted == 0)
    }

    @Test("Closing the transport cancels an upload in flight, and no later batch is sent")
    func closingStopsAnUploadInFlight() async throws {
        database.update { $0.modifiesToHold = 1 }
        let upload = Task {
            try await transport.modify(account: "_alice", saves: [Self.tag("Tag_A")], deletes: [])
        }
        try await waitUntil { database.modifyStarted == 1 }

        transport.close()
        let first = await upload.result
        let second = await failure {
            _ = try await transport.modify(account: "_alice", saves: [Self.tag("Tag_B")], deletes: [])
        }

        #expect(throws: CloudKitFailure.self) { try first.get() }
        #expect(database.read { $0.modifiesCancelled } == 1)
        #expect(second == .Other(code: Int64(CKError.Code.operationCancelled.rawValue)))
        #expect(database.modifyStarted == 1)
    }

    @Test("The engine dropping a call cancels its CloudKit operation")
    func droppedCallCancelsTheOperation() async throws {
        database.update { $0.modifiesToHold = 1 }
        let upload = Task {
            try await transport.modify(account: "_alice", saves: [Self.tag("Tag_A")], deletes: [])
        }
        try await waitUntil { database.modifyStarted == 1 }

        upload.cancel()
        _ = await upload.result

        #expect(database.read { $0.modifiesCancelled } == 1)
    }

    @Test("A refused zone save fails the call with CloudKit's reason")
    func singleItemFailure() async throws {
        database.update { $0.failure = CKError(.quotaExceeded) }

        let outcome = await failure { try await transport.ensureZone(account: "_alice") }

        #expect(outcome == .QuotaExceeded)
    }

    @Test("An account change cancels what is in flight and leaves the transport open")
    func accountChangeCancelsInFlight() async throws {
        database.update { $0.modifiesToHold = 1 }
        let upload = Task {
            try await transport.modify(account: "_alice", saves: [Self.tag("Tag_A")], deletes: [])
        }
        try await waitUntil { database.modifyStarted == 1 }

        transport.cancelCallsInFlight()
        let cancelled = await upload.result
        let outcomes = try await transport.modify(account: "_alice", saves: [Self.tag("Tag_B")], deletes: [])

        #expect(database.read { $0.modifiesCancelled } == 1)
        #expect(throws: CloudKitFailure.AccountChanged) { try cancelled.get() }
        #expect(!transport.isClosed)
        guard case .saved = try #require(outcomes.first) else {
            Issue.record("not saved: \(outcomes)")
            return
        }
    }

    static func changeToken() throws -> CKServerChangeToken {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("CKServerChangeToken", for: TransportChangeTokenArchive.self)
        archiver.encode(TransportChangeTokenArchive(), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: archiver.encodedData)
        return try #require(token)
    }
}

@objc(CloudKitCoreTransportTestsChangeTokenArchive)
private final class TransportChangeTokenArchive: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {}
}
