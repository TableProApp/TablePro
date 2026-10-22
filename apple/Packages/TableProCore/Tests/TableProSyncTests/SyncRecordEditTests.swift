import CloudKit
import Foundation
import Testing

@testable import TableProSyncTransport

struct SyncRecordEditTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

    private func serverRecord(_ values: [ConnectionSyncField: Any]) -> CKRecord {
        let record = CKRecord(
            recordType: SyncRecordType.connection.rawValue,
            recordID: CKRecord.ID(recordName: SyncRecordType.connection.recordName(for: "a"), zoneID: zoneID)
        )
        let fields = record.fields(ConnectionSyncField.self)
        for (field, value) in values {
            fields[field] = value
        }
        return record
    }

    private func copy(_ record: CKRecord) throws -> CKRecord {
        try #require(record.copy() as? CKRecord)
    }

    private func value(_ field: ConnectionSyncField, in record: CKRecord) -> Any? {
        record.fields(ConnectionSyncField.self)[field]
    }

    @Test("An edit holds only the fields the push changed on its base")
    func editHoldsChangedFields() throws {
        let base = serverRecord([.name: "Production", .port: Int64(5_432), .host: "db"])
        let pushed = try copy(base)
        pushed.fields(ConnectionSyncField.self)[.port] = Int64(6_543)

        let edit = SyncRecordEdit(ConnectionSyncField.self, record: pushed, base: base)

        #expect(edit.editedKeys == [ConnectionSyncField.port.key])
    }

    @Test("A rebased edit keeps the fields another device changed on the newer copy")
    func rebaseKeepsServerFields() throws {
        let base = serverRecord([.name: "Production", .port: Int64(5_432)])
        let pushed = try copy(base)
        pushed.fields(ConnectionSyncField.self)[.port] = Int64(6_543)
        let server = try copy(base)
        server.fields(ConnectionSyncField.self)[.name] = "Renamed elsewhere"

        let merged = try #require(SyncRecordEdit(ConnectionSyncField.self, record: pushed, base: base).rebased(onto: server))

        #expect(value(.name, in: merged) as? String == "Renamed elsewhere")
        #expect(value(.port, in: merged) as? Int64 == 6_543)
    }

    @Test("A value this device only spells differently is not part of the edit")
    func respelledValueIsNotAnEdit() throws {
        let base = serverRecord([.name: "Production", .sshConfigJson: Data(#"{"b":1,"a":2}"#.utf8)])
        let asWritten = serverRecord([.name: "Production", .sshConfigJson: Data(#"{"a":2,"b":1}"#.utf8)])
        let pushed = try copy(base)
        pushed.fields(ConnectionSyncField.self)[.sshConfigJson] = Data(#"{"a":2,"b":1}"#.utf8)
        pushed.fields(ConnectionSyncField.self)[.name] = "Renamed here"
        let server = try copy(base)
        let newer = Data(#"{"a":3,"b":1}"#.utf8)
        server.fields(ConnectionSyncField.self)[.sshConfigJson] = newer

        let edit = SyncRecordEdit(ConnectionSyncField.self, record: pushed, base: base, baseAsWritten: asWritten)
        let merged = try #require(edit.rebased(onto: server))

        #expect(edit.editedKeys == [ConnectionSyncField.name.key])
        #expect(value(.sshConfigJson, in: merged) as? Data == newer)
        #expect(value(.name, in: merged) as? String == "Renamed here")
    }

    @Test("A field the edit emptied is emptied on the newer copy")
    func clearedFieldStaysCleared() throws {
        let base = serverRecord([.name: "Production", .aiRules: "Be careful"])
        let pushed = try copy(base)
        pushed.fields(ConnectionSyncField.self)[.aiRules] = nil
        let server = try copy(base)
        server.fields(ConnectionSyncField.self)[.aiRules] = "Be very careful"

        let merged = try #require(SyncRecordEdit(ConnectionSyncField.self, record: pushed, base: base).rebased(onto: server))

        #expect(value(.aiRules, in: merged) == nil)
        #expect(Set(merged.changedKeys()).contains(ConnectionSyncField.aiRules.key))
    }

    @Test("A key an earlier save left in changedKeys is not part of the edit")
    func staleChangedKeysAreIgnored() throws {
        let base = serverRecord([.name: "Production", .port: Int64(5_432)])
        #expect(Set(base.changedKeys()).contains(ConnectionSyncField.name.key))
        let pushed = try copy(base)
        pushed.fields(ConnectionSyncField.self)[.port] = Int64(6_543)

        #expect(SyncRecordEdit(ConnectionSyncField.self, record: pushed, base: base).editedKeys == [ConnectionSyncField.port.key])
    }

    @Test("A record built with no base sends every field it names")
    func freshRecordSendsEveryNamedField() {
        let fresh = serverRecord([.name: "Production", .port: Int64(5_432)])

        let edit = SyncRecordEdit(ConnectionSyncField.self, record: fresh, base: nil)

        #expect(edit.editedKeys == [ConnectionSyncField.name.key, ConnectionSyncField.port.key])
    }

    @Test("The settle step sees the merged record and the server's copy")
    func settleAdjustsTheMergedRecord() throws {
        let base = serverRecord([.name: "Production"])
        let pushed = try copy(base)
        pushed.fields(ConnectionSyncField.self)[.name] = "Mine"
        let server = try copy(base)
        server.fields(ConnectionSyncField.self)[.name] = "Theirs"

        let edit = SyncRecordEdit(ConnectionSyncField.self, record: pushed, base: base) { merged, server in
            merged.fields(ConnectionSyncField.self)[.name] = server.fields(ConnectionSyncField.self)[.name]
        }

        let merged = try #require(edit.rebased(onto: server))
        #expect(value(.name, in: merged) as? String == "Theirs")
    }

    @Test("An edit lands only on a copy of its own record")
    func rebaseRefusesAnotherRecord() {
        let pushed = serverRecord([.name: "Production"])
        let other = CKRecord(
            recordType: SyncRecordType.connection.rawValue,
            recordID: CKRecord.ID(recordName: SyncRecordType.connection.recordName(for: "b"), zoneID: zoneID)
        )

        #expect(SyncRecordEdit(ConnectionSyncField.self, record: pushed, base: nil).rebased(onto: other) == nil)
    }

    @Test("Saves are refused when the server's copy moved on")
    func savesAreConditional() {
        let operation = CloudKitSyncEngine.modifyOperation(saving: [], deleting: [])

        #expect(operation.savePolicy == .ifServerRecordUnchanged)
        #expect(operation.isAtomic == false)
    }

    // MARK: - Rebase loop

    private func conflict(_ server: CKRecord) -> SyncItemFailure {
        SyncItemFailure(code: .serverRecordChanged, serverRecord: server, clientRecord: nil, message: "changed")
    }

    @Test("A refused push is merged onto the server's copy and sent again")
    func refusedPushIsRebased() async throws {
        let base = serverRecord([.name: "Production", .port: Int64(5_432)])
        let pushed = try copy(base)
        pushed.fields(ConnectionSyncField.self)[.port] = Int64(6_543)
        let server = try copy(base)
        server.fields(ConnectionSyncField.self)[.name] = "Renamed elsewhere"
        let edit = SyncRecordEdit(ConnectionSyncField.self, record: pushed, base: base)
        var sent: [[CKRecord]] = []
        let failure = conflict(server)

        let outcome = try await SyncConflictRebase.push(
            records: [pushed],
            deletions: [],
            edits: [edit.recordID: edit]
        ) { records, _ in
            sent.append(records)
            guard sent.count > 1 else { return PushOutcome(failures: [edit.recordID: failure]) }
            return PushOutcome(savedRecords: Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, $0) }))
        } fetch: { _ in [:] }

        #expect(sent.count == 2)
        let retried = try #require(sent.last?.first)
        #expect(value(.name, in: retried) as? String == "Renamed elsewhere")
        #expect(value(.port, in: retried) as? Int64 == 6_543)
        #expect(outcome.didSave(edit.recordID))
        #expect(outcome.hasFailures == false)
        #expect(outcome.rebasedRecordIDs == [edit.recordID])
        #expect(outcome.savedRecordsOfLocalCopies.isEmpty)
    }

    @Test("A record refused in every round stays pending")
    func rebaseStopsAtTheLimit() async throws {
        let base = serverRecord([.name: "Production"])
        let pushed = try copy(base)
        pushed.fields(ConnectionSyncField.self)[.name] = "Mine"
        let edit = SyncRecordEdit(ConnectionSyncField.self, record: pushed, base: base)
        let failure = conflict(try copy(base))
        var sends = 0

        let outcome = try await SyncConflictRebase.push(
            records: [pushed],
            deletions: [],
            edits: [edit.recordID: edit]
        ) { _, _ in
            sends += 1
            return PushOutcome(failures: [edit.recordID: failure])
        } fetch: { _ in [:] }

        #expect(sends == 1 + SyncRecordEdit.rebaseLimit)
        #expect(outcome.failures[edit.recordID]?.isConflict == true)
    }

    // MARK: - Settings options

    private func json(_ text: String) -> Data {
        Data(text.utf8)
    }

    private func parsed(_ data: Data?) throws -> Any {
        let data = try #require(data)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func options(_ data: Data?) throws -> NSDictionary {
        let document = try parsed(data) as? NSDictionary
        return try #require(document)
    }

    @Test("Two devices changing different options of one category keep both")
    func optionsChangedOnEachSideAreKept() throws {
        let merged = SyncJSONMerge.document(
            base: json(#"{"rowHeight":20,"zebra":false,"font":"Menlo"}"#),
            local: json(#"{"font":"Menlo","rowHeight":24,"zebra":false}"#),
            server: json(#"{"rowHeight":20,"zebra":true,"font":"Menlo"}"#)
        )

        #expect(try options(merged) == ["rowHeight": 24, "zebra": true, "font": "Menlo"])
    }

    @Test("An option removed here is removed from the server's object")
    func removedOptionIsRemoved() throws {
        let merged = SyncJSONMerge.document(
            base: json(#"{"a":1,"b":2}"#),
            local: json(#"{"a":1}"#),
            server: json(#"{"a":3,"b":2}"#)
        )

        #expect(try options(merged) == ["a": 3])
    }

    @Test("Values both sides changed, outside a keyed list, take this device's")
    func bothChangedTakesLocal() throws {
        let merged = SyncJSONMerge.document(base: json("[1]"), local: json("[1,2]"), server: json("[3]"))

        let list = try parsed(merged) as? [Int]
        #expect(list == [1, 2])
        #expect(SyncJSONMerge.document(base: nil, local: json(#"{"a":1}"#), server: json(#"{"a":2}"#)) == nil)
    }

    @Test("A document this device only spelled differently leaves the server's untouched")
    func respelledDocumentKeepsTheServers() {
        let server = json(#"[{"id":"1","name":"a"},{"id":"2","name":"b"}]"#)

        let merged = SyncJSONMerge.document(
            base: json(#"[{"name":"a","id":"1"}]"#),
            local: json(#"[{"id":"1","name":"a"}]"#),
            server: server
        )

        #expect(merged == server)
    }

    @Test("Items with an id added on each side are both kept, and one removed here is removed")
    func keyedListsMergeByItem() throws {
        let merged = SyncJSONMerge.document(
            base: json(#"[{"id":"1","name":"a"},{"id":"2","name":"b"}]"#),
            local: json(#"[{"id":"1","name":"a2"},{"id":"3","name":"c"}]"#),
            server: json(#"[{"id":"1","name":"a"},{"id":"2","name":"b"},{"id":"4","name":"d"}]"#)
        )

        let items = try parsed(merged) as? [[String: String]]
        #expect(items == [["id": "1", "name": "a2"], ["id": "4", "name": "d"], ["id": "3", "name": "c"]])
    }

    @Test("Options nested in an object merge one by one")
    func nestedObjectsMerge() throws {
        let merged = SyncJSONMerge.document(
            base: json(#"{"shortcuts":{"x":1,"y":1}}"#),
            local: json(#"{"shortcuts":{"x":2,"y":1}}"#),
            server: json(#"{"shortcuts":{"x":1,"y":3}}"#)
        )

        #expect(try options(merged) == ["shortcuts": ["x": 2, "y": 3]])
    }

    @Test("An edit of only the stamps every push writes changes no content")
    func stampsAreNotContent() throws {
        let base = serverRecord([.name: "Production", .modifiedAtLocal: Date(timeIntervalSince1970: 1)])
        let pushed = try copy(base)
        pushed.fields(ConnectionSyncField.self)[.modifiedAtLocal] = Date(timeIntervalSince1970: 2)

        #expect(SyncRecordEdit(ConnectionSyncField.self, record: pushed, base: base).changesContent == false)
        pushed.fields(ConnectionSyncField.self)[.name] = "Renamed"
        #expect(SyncRecordEdit(ConnectionSyncField.self, record: pushed, base: base).changesContent)
    }

    @Test("A record deleted elsewhere goes up again whole, as a new record")
    func missingRecordIsRecreated() async throws {
        let base = serverRecord([.name: "Production", .port: Int64(5_432)])
        let pushed = try copy(base)
        pushed.fields(ConnectionSyncField.self)[.port] = Int64(6_543)
        let edit = SyncRecordEdit(ConnectionSyncField.self, record: pushed, base: base)
        let missing = SyncItemFailure(code: .unknownItem, serverRecord: nil, clientRecord: nil, message: "Record not found")
        var sent: [[CKRecord]] = []

        let outcome = try await SyncConflictRebase.push(records: [pushed], deletions: [], edits: [edit.recordID: edit]) { records, _ in
            sent.append(records)
            guard sent.count > 1 else { return PushOutcome(failures: [edit.recordID: missing]) }
            return PushOutcome(savedRecords: Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, $0) }))
        } fetch: { _ in [:] }

        let recreated = try #require(sent.last?.first)
        #expect(recreated !== pushed)
        #expect(value(.name, in: recreated) as? String == "Production")
        #expect(value(.port, in: recreated) as? Int64 == 6_543)
        #expect(outcome.didSave(edit.recordID))
        #expect(outcome.rebasedRecordIDs.isEmpty)
    }

    @Test("A refusal that names no server copy reads it and merges onto it")
    func refusalWithoutCopyFetchesIt() async throws {
        let base = serverRecord([.name: "Production", .port: Int64(5_432)])
        let pushed = try copy(base)
        pushed.fields(ConnectionSyncField.self)[.port] = Int64(6_543)
        let server = try copy(base)
        server.fields(ConnectionSyncField.self)[.name] = "Renamed elsewhere"
        let edit = SyncRecordEdit(ConnectionSyncField.self, record: pushed, base: base)
        let refusal = SyncItemFailure(code: .serverRecordChanged, serverRecord: nil, clientRecord: nil, message: "changed")
        var sent: [[CKRecord]] = []

        let outcome = try await SyncConflictRebase.push(records: [pushed], deletions: [], edits: [edit.recordID: edit]) { records, _ in
            sent.append(records)
            guard sent.count > 1 else { return PushOutcome(failures: [edit.recordID: refusal]) }
            return PushOutcome(savedRecords: Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, $0) }))
        } fetch: { recordIDs in
            Dictionary(uniqueKeysWithValues: recordIDs.map { ($0, server) })
        }

        let retried = try #require(sent.last?.first)
        #expect(value(.name, in: retried) as? String == "Renamed elsewhere")
        #expect(value(.port, in: retried) as? Int64 == 6_543)
        #expect(outcome.didSave(edit.recordID))
    }

    @Test("A merge round that throws keeps what the first round saved and the refusal still pending")
    func throwingRoundKeepsEarlierOutcome() async throws {
        let base = serverRecord([.name: "Production"])
        let pushed = try copy(base)
        pushed.fields(ConnectionSyncField.self)[.name] = "Mine"
        let edit = SyncRecordEdit(ConnectionSyncField.self, record: pushed, base: base)
        let saved = CKRecord(
            recordType: SyncRecordType.connection.rawValue,
            recordID: CKRecord.ID(recordName: SyncRecordType.connection.recordName(for: "b"), zoneID: zoneID)
        )
        let failure = conflict(try copy(base))
        var sends = 0

        do {
            _ = try await SyncConflictRebase.push(
                records: [pushed, saved],
                deletions: [],
                edits: [edit.recordID: edit]
            ) { _, _ in
                sends += 1
                guard sends == 1 else { throw CKError(.networkFailure) }
                return PushOutcome(savedRecords: [saved.recordID: saved], failures: [edit.recordID: failure])
            } fetch: { _ in [:] }
            Issue.record("Expected the merge round to throw")
        } catch let interruption as SyncPushInterruption {
            #expect(interruption.completed.didSave(saved.recordID))
            #expect(interruption.completed.failures[edit.recordID]?.isConflict == true)
            #expect(interruption.completed.savedRecordsOfLocalCopies.map(\.recordID) == [saved.recordID])
            #expect(SyncFailure(interruption) == .offline)
        }
    }

    @Test("A later save clears the failure an earlier push reported for the same record")
    func laterSaveClearsEarlierFailure() {
        let record = serverRecord([.name: "Production"])
        var outcome = PushOutcome(failures: [record.recordID: conflict(record)])

        outcome.merge(PushOutcome(savedRecords: [record.recordID: record]))

        #expect(outcome.didSave(record.recordID))
        #expect(outcome.hasFailures == false)
    }
}
