import CloudKit
import Foundation

// The fields a push changes on the server record it was built on, so the same change can be made
// again on the server's newer copy when CloudKit refuses the push.
public struct SyncRecordEdit {
    public static let rebaseLimit = 2

    public let record: CKRecord
    public let editedKeys: Set<String>
    public let hasBase: Bool
    private let apply: (CKRecord) -> Void
    private let whole: () -> CKRecord
    private let settle: ((_ merged: CKRecord, _ server: CKRecord) -> Void)?

    // `base` is an untouched copy of what `record` was built on, compared value by value: an archived
    // or copied record keeps its `changedKeys()`, so a cached record can still name keys an earlier save
    // sent. `baseAsWritten` is `base` read and written again by this device, so a value this device only
    // spells differently is not an edit.
    public init<Field: SyncSchemaField>(
        _: Field.Type,
        record: CKRecord,
        base: CKRecord?,
        baseAsWritten: CKRecord? = nil,
        settle: ((_ merged: CKRecord, _ server: CKRecord) -> Void)? = nil
    ) {
        let pushed = record.fields(Field.self)
        let base = base.flatMap { $0.recordID == record.recordID ? $0 : nil }
        let edited: [Field]
        if let base {
            let original = base.fields(Field.self)
            let written = baseAsWritten?.fields(Field.self)
            edited = Field.allCases.filter { field in
                !CKRecord.isEqualRecordValue(pushed[field], original[field])
                    && !(written.map { CKRecord.isEqualRecordValue(pushed[field], $0[field]) } ?? false)
            }
        } else {
            let named = Set(record.changedKeys())
            edited = Field.allCases.filter { named.contains($0.key) }
        }
        let values = edited.map { (field: $0, value: pushed[$0]) }

        self.record = record
        self.editedKeys = Set(edited.map(\.key))
        self.hasBase = base != nil
        self.apply = { target in
            let fields = target.fields(Field.self, absentValues: .clear)
            for (field, value) in values {
                fields[field] = value
            }
        }
        self.whole = {
            let fresh = CKRecord(recordType: record.recordType, recordID: record.recordID)
            let fields = fresh.fields(Field.self)
            for field in Field.allCases {
                fields[field] = pushed[field]
            }
            return fresh
        }
        self.settle = settle
    }

    public var recordID: CKRecord.ID { record.recordID }

    // Every push stamps these, so an edit holding only them changes nothing a person made.
    public var changesContent: Bool {
        !editedKeys.subtracting(["modifiedAtLocal", "schemaVersion"]).isEmpty
    }

    // The server no longer holds the record (deleted elsewhere, or its zone made again), so the whole
    // local copy goes up as a new one, as a push built with no cached record always did.
    public func recreated() -> CKRecord {
        whole()
    }

    // Carries the server's change tag, so CloudKit saves it only while that copy is still the latest.
    public func rebased(onto server: CKRecord) -> CKRecord? {
        guard server.recordID == record.recordID, server.recordType == record.recordType,
              let merged = server.copy() as? CKRecord
        else { return nil }
        apply(merged)
        settle?(merged, server)
        return merged
    }
}

public enum SyncConflictRebase {
    // A record still refused after the last round stays a failure, pending for the next run. `fetch`
    // reads the server's copy when a refusal arrives without one.
    public static func push(
        records: [CKRecord],
        deletions: [CKRecord.ID],
        edits: [CKRecord.ID: SyncRecordEdit],
        isolation: isolated (any Actor)? = #isolation,
        send: (_ records: [CKRecord], _ deletions: [CKRecord.ID]) async throws -> PushOutcome,
        fetch: (_ recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: CKRecord]
    ) async throws -> PushOutcome {
        var outcome = try await send(records, deletions)
        for _ in 0..<SyncRecordEdit.rebaseLimit {
            let refused = outcome.failures.filter { recordID, failure in
                guard let edit = edits[recordID] else { return false }
                return failure.isConflict || (failure.code == .unknownItem && edit.hasBase)
            }
            guard !refused.isEmpty else { break }
            let unread = refused.filter { $0.value.isConflict && $0.value.serverRecord == nil }.map(\.key)
            let fetched = unread.isEmpty ? [:] : (try? await fetch(unread)) ?? [:]

            var retries: [CKRecord] = []
            var rebased: [CKRecord.ID] = []
            for (recordID, failure) in refused {
                guard let edit = edits[recordID] else { continue }
                if failure.code == .unknownItem {
                    retries.append(edit.recreated())
                } else if let server = failure.serverRecord ?? fetched[recordID], let merged = edit.rebased(onto: server) {
                    retries.append(merged)
                    rebased.append(recordID)
                }
            }
            guard !retries.isEmpty else { break }
            outcome.markRebased(rebased)
            do {
                outcome.merge(try await send(retries, []))
            } catch {
                throw SyncPushInterruption.after(outcome, failingWith: error)
            }
        }
        return outcome
    }
}

// Settings are JSON documents of independent options, so two devices changing different options keep
// both: what this device changed since `base` lands on the server's document, objects merged key by key
// and lists of objects with an `id` item by item. Where both changed one value, this device's wins.
public enum SyncJSONMerge {
    public static func document(base: Data?, local: Data?, server: Data?) -> Data? {
        guard let base = parse(base), let local = parse(local), let serverData = server, let server = parse(server)
        else { return nil }
        if isEqual(local, base) { return serverData }
        return try? JSONSerialization.data(
            withJSONObject: merge(base: base, local: local, server: server),
            options: [.sortedKeys, .fragmentsAllowed]
        )
    }

    private static func merge(base: Any?, local: Any, server: Any) -> Any {
        if isEqual(local, base) { return server }
        if isEqual(server, base) { return local }
        if let base = base as? [String: Any], let local = local as? [String: Any], let server = server as? [String: Any] {
            return mergeObjects(base: base, local: local, server: server)
        }
        if let base = base as? [Any], let local = local as? [Any], let server = server as? [Any],
           let merged = mergeLists(base: base, local: local, server: server) {
            return merged
        }
        return local
    }

    private static func mergeObjects(base: [String: Any], local: [String: Any], server: [String: Any]) -> [String: Any] {
        var merged = server
        for key in Set(local.keys).union(base.keys) where !isEqual(local[key], base[key]) {
            guard let value = local[key] else {
                merged.removeValue(forKey: key)
                continue
            }
            merged[key] = server[key].map { merge(base: base[key], local: value, server: $0) } ?? value
        }
        return merged
    }

    private static func mergeLists(base: [Any], local: [Any], server: [Any]) -> [Any]? {
        guard let baseItems = keyed(base), let localItems = keyed(local), let serverItems = keyed(server) else { return nil }
        let baseIds = Set(baseItems.map(\.id))
        let localIds = Set(localItems.map(\.id))
        let serverIds = Set(serverItems.map(\.id))
        let baseById = Dictionary(uniqueKeysWithValues: baseItems.map { ($0.id, $0.item) })
        let localById = Dictionary(uniqueKeysWithValues: localItems.map { ($0.id, $0.item) })

        var merged: [Any] = serverItems.compactMap { entry in
            guard !(baseIds.contains(entry.id) && !localIds.contains(entry.id)) else { return nil }
            guard let mine = localById[entry.id], !isEqual(mine, baseById[entry.id]) else { return entry.item }
            return merge(base: baseById[entry.id], local: mine, server: entry.item)
        }
        // Added here, or changed here while another device removed it.
        for entry in localItems where !serverIds.contains(entry.id) && !isEqual(entry.item, baseById[entry.id]) {
            merged.append(entry.item)
        }
        return merged
    }

    private static func keyed(_ list: [Any]) -> [(id: String, item: Any)]? {
        var seen: Set<String> = []
        var keyed: [(id: String, item: Any)] = []
        for item in list {
            guard let object = item as? [String: Any], let id = object["id"].map({ "\($0)" }), seen.insert(id).inserted
            else { return nil }
            keyed.append((id, item))
        }
        return keyed
    }

    private static func parse(_ data: Data?) -> Any? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
    }

    private static func isEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let lhs as NSObject, let rhs as NSObject):
            return lhs.isEqual(rhs)
        default:
            return false
        }
    }
}
