import Foundation

enum TableHealthFindingStatus: String, Sendable {
    case new
    case ignored
    case none
}

// What one database's findings did across recorded runs. Every rule runs on run numbers and dates are only shown, so
// a clock change cannot reorder history.
struct TableHealthLedger: Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        var firstSeenRun: Int
        var firstSeen: Date
        var lastSeen: Date
        var resolvedRun: Int?
        var resolvedAt: Date?
    }

    struct ResolvedFinding: Identifiable, Sendable, Equatable {
        let id: TableHealthFindingID
        let firstSeen: Date
        let lastSeen: Date
        let resolvedAt: Date
        let resolvedRun: Int
    }

    static let resolvedLimit = 1_000

    private(set) var runIndex = 0
    private(set) var entries: [TableHealthFindingID: Entry] = [:]
    private(set) var ignored: [TableHealthFindingID: Date] = [:]
    // Keyed by the kind's raw value.
    private var firstCompletedRun: [String: Int] = [:]
    private var lastCompletedRun: [String: Int] = [:]
    // What a newer build wrote under a kind this one does not know, kept as read so going back and forth loses nothing.
    private var unknownEntries: [String: TableHealthLedgerJSON] = [:]
    private var unknownIgnored: [String: TableHealthLedgerJSON] = [:]

    init() {}

    // Only a check that completed moves its entries: one that failed or was skipped says nothing about what is there.
    func recording(_ report: TableHealthReport, at date: Date) -> TableHealthLedger {
        var next = self
        next.runIndex += 1
        let run = next.runIndex
        for result in report.checks where result.outcome == .completed {
            let present = Set(result.findings.map(\.id))
            for id in present {
                if var entry = next.entries[id], entry.resolvedRun == nil {
                    entry.lastSeen = date
                    next.entries[id] = entry
                } else {
                    next.entries[id] = Entry(firstSeenRun: run, firstSeen: date, lastSeen: date)
                }
            }
            for (id, entry) in next.entries
            where id.kind == result.kind && entry.resolvedRun == nil && !present.contains(id) {
                var resolved = entry
                resolved.resolvedRun = run
                resolved.resolvedAt = date
                next.entries[id] = resolved
            }
            let kind = result.kind.rawValue
            if next.firstCompletedRun[kind] == nil {
                next.firstCompletedRun[kind] = run
            }
            next.lastCompletedRun[kind] = run
        }
        next.trimResolved()
        return next
    }

    // New: first seen in the latest run, by a check that had completed in an earlier one. A check's first completion
    // has nothing to compare with, so it marks nothing new.
    func status(of id: TableHealthFindingID) -> TableHealthFindingStatus {
        if ignored[id] != nil { return .ignored }
        guard let entry = entries[id], entry.resolvedRun == nil, entry.firstSeenRun == runIndex,
              let firstCompletion = firstCompletedRun[id.kind.rawValue], firstCompletion < entry.firstSeenRun
        else { return .none }
        return .new
    }

    // For a report read without recording it: new when recording it would mark the finding new.
    func mcpStatus(of id: TableHealthFindingID) -> TableHealthFindingStatus {
        if ignored[id] != nil { return .ignored }
        if let entry = entries[id], entry.resolvedRun == nil { return .none }
        return lastCompletedRun[id.kind.rawValue] == nil ? .none : .new
    }

    func firstSeen(_ id: TableHealthFindingID) -> Date? {
        entries[id]?.firstSeen
    }

    func lastSeen(_ id: TableHealthFindingID) -> Date? {
        entries[id]?.lastSeen
    }

    func isIgnored(_ id: TableHealthFindingID) -> Bool {
        ignored[id] != nil
    }

    var resolved: [ResolvedFinding] {
        entries
            .filter { $0.value.resolvedRun != nil }
            .sorted(by: Self.resolvedFirst)
            .map { id, entry in
                ResolvedFinding(
                    id: id,
                    firstSeen: entry.firstSeen,
                    lastSeen: entry.lastSeen,
                    resolvedAt: entry.resolvedAt ?? entry.lastSeen,
                    resolvedRun: entry.resolvedRun ?? 0
                )
            }
    }

    // An ignore outlives the finding, so an accepted index that is dropped and built again stays ignored.
    func ignoring(_ ids: some Sequence<TableHealthFindingID>, at date: Date) -> TableHealthLedger {
        var next = self
        for id in ids where next.ignored[id] == nil {
            next.ignored[id] = date
        }
        return next
    }

    func unignoring(_ ids: some Sequence<TableHealthFindingID>) -> TableHealthLedger {
        var next = self
        for id in ids {
            next.ignored[id] = nil
        }
        return next
    }

    func clearingResolved() -> TableHealthLedger {
        var next = self
        next.entries = entries.filter { $0.value.resolvedRun == nil }
        return next
    }

    func renamingTable(schema: String?, from oldName: String, to newName: String) -> TableHealthLedger {
        rewritingKeys { key in
            guard key.schema == schema, key.table == oldName else { return key }
            var moved = key
            moved.table = newName
            return moved
        }
    }

    func renamingSchema(from oldName: String, to newName: String) -> TableHealthLedger {
        rewritingKeys { key in
            guard key.schema == oldName else { return key }
            var moved = key
            moved.schema = newName
            return moved
        }
    }

    func droppingTable(schema: String?, name: String) -> TableHealthLedger {
        removingKeys { $0.schema == schema && $0.table == name }
    }

    func droppingSchema(_ schema: String) -> TableHealthLedger {
        removingKeys { $0.schema == schema }
    }

    private func rewritingKeys(_ transform: (TableHealthStorageKey) -> TableHealthStorageKey) -> TableHealthLedger {
        var next = self
        next.entries = Self.rekeyed(entries) { TableHealthFindingID(parts: transform($0.storageParts)) ?? $0 }
        next.ignored = Self.rekeyed(ignored) { TableHealthFindingID(parts: transform($0.storageParts)) ?? $0 }
        next.unknownEntries = Self.rekeyed(unknownEntries) { key in
            TableHealthStorageKey(encoded: key).map { transform($0).encoded } ?? key
        }
        next.unknownIgnored = Self.rekeyed(unknownIgnored) { key in
            TableHealthStorageKey(encoded: key).map { transform($0).encoded } ?? key
        }
        return next
    }

    private func removingKeys(_ isGone: (TableHealthStorageKey) -> Bool) -> TableHealthLedger {
        var next = self
        next.entries = entries.filter { !isGone($0.key.storageParts) }
        next.ignored = ignored.filter { !isGone($0.key.storageParts) }
        next.unknownEntries = unknownEntries.filter { TableHealthStorageKey(encoded: $0.key).map { !isGone($0) } ?? true }
        next.unknownIgnored = unknownIgnored.filter { TableHealthStorageKey(encoded: $0.key).map { !isGone($0) } ?? true }
        return next
    }

    // A moved key wins over one already there: the object was renamed onto that name, so what is there is stale.
    private static func rekeyed<Key: Hashable, Value>(_ source: [Key: Value], _ move: (Key) -> Key) -> [Key: Value] {
        var result: [Key: Value] = [:]
        var moved: [(Key, Value)] = []
        for (key, value) in source {
            let target = move(key)
            if target == key {
                result[key] = value
            } else {
                moved.append((target, value))
            }
        }
        for (key, value) in moved {
            result[key] = value
        }
        return result
    }

    private mutating func trimResolved() {
        let resolved = entries.filter { $0.value.resolvedRun != nil }
        guard resolved.count > Self.resolvedLimit else { return }
        for (id, _) in resolved.sorted(by: Self.resolvedFirst).dropFirst(Self.resolvedLimit) {
            entries[id] = nil
        }
    }

    private static func resolvedFirst(
        _ lhs: (key: TableHealthFindingID, value: Entry),
        _ rhs: (key: TableHealthFindingID, value: Entry)
    ) -> Bool {
        let lhsRun = lhs.value.resolvedRun ?? 0, rhsRun = rhs.value.resolvedRun ?? 0
        if lhsRun != rhsRun { return lhsRun > rhsRun }
        let lhsDate = lhs.value.resolvedAt ?? .distantPast, rhsDate = rhs.value.resolvedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.key.storageKey < rhs.key.storageKey
    }
}

extension TableHealthLedger: Codable {
    private enum CodingKeys: String, CodingKey {
        case runIndex
        case entries
        case ignored
        case firstCompletedRun
        case lastCompletedRun
    }

    private struct StorageKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    // A key this build cannot read as a finding id is kept verbatim. An entry of a known kind that does not decode is
    // dropped: keeping it beside the entry a later run writes would give the file the key twice.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runIndex = try container.decodeIfPresent(Int.self, forKey: .runIndex) ?? 0
        firstCompletedRun = try container.decodeIfPresent([String: Int].self, forKey: .firstCompletedRun) ?? [:]
        lastCompletedRun = try container.decodeIfPresent([String: Int].self, forKey: .lastCompletedRun) ?? [:]
        if container.contains(.entries) {
            let stored = try container.nestedContainer(keyedBy: StorageKey.self, forKey: .entries)
            for key in stored.allKeys {
                if let id = TableHealthFindingID(storageKey: key.stringValue) {
                    if let entry = try? stored.decode(Entry.self, forKey: key) {
                        entries[id] = entry
                    }
                } else {
                    unknownEntries[key.stringValue] = try stored.decode(TableHealthLedgerJSON.self, forKey: key)
                }
            }
        }
        if container.contains(.ignored) {
            let stored = try container.nestedContainer(keyedBy: StorageKey.self, forKey: .ignored)
            for key in stored.allKeys {
                if let id = TableHealthFindingID(storageKey: key.stringValue) {
                    if let date = try? stored.decode(Date.self, forKey: key) {
                        ignored[id] = date
                    }
                } else {
                    unknownIgnored[key.stringValue] = try stored.decode(TableHealthLedgerJSON.self, forKey: key)
                }
            }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runIndex, forKey: .runIndex)
        try container.encode(firstCompletedRun, forKey: .firstCompletedRun)
        try container.encode(lastCompletedRun, forKey: .lastCompletedRun)
        var storedEntries = container.nestedContainer(keyedBy: StorageKey.self, forKey: .entries)
        for (key, value) in unknownEntries {
            try storedEntries.encode(value, forKey: StorageKey(key))
        }
        for (id, entry) in entries {
            try storedEntries.encode(entry, forKey: StorageKey(id.storageKey))
        }
        var storedIgnored = container.nestedContainer(keyedBy: StorageKey.self, forKey: .ignored)
        for (key, value) in unknownIgnored {
            try storedIgnored.encode(value, forKey: StorageKey(key))
        }
        for (id, date) in ignored {
            try storedIgnored.encode(date, forKey: StorageKey(id.storageKey))
        }
    }
}

private indirect enum TableHealthLedgerJSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([TableHealthLedgerJSON])
    case object([String: TableHealthLedgerJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([TableHealthLedgerJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: TableHealthLedgerJSON].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
