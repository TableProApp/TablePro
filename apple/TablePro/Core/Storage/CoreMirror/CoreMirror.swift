//
//  CoreMirror.swift
//  TablePro
//

import CryptoKit
import Foundation
import os
import TableProLogRedaction

// A Swift store the previous stable reads, and the core's copy of it in history.db, each record under its own id
// (core ADR 0010, slices 3 and 9). The Swift store stays what this build reads and writes first; every write
// reaches the core after it, and a push compares both sides record by record with what they held when they last
// agreed, so a change on either side, the previous stable's included, goes to the other.
internal protocol CoreMirrorAdapter: Sendable {
    associatedtype Key: Hashable & Sendable & Encodable
    associatedtype Value: Equatable & Sendable & Encodable

    var name: String { get }
    func key(of value: Value) -> Key
    // Nil when the Swift store cannot be read: nothing goes to the core then.
    func readLegacy() async -> CoreMirrorLegacyRead<Value>?
    func readCore() async throws -> CoreMirrorCoreRead<Value>
    func writeCore(puts: [Value], removals: [Key]) async throws
    // Whole, refused with `CoreMirrorError.outdated` when the core no longer holds what `expected` names.
    func replaceCore(expected: String, values: [Value]) async throws
    // Only when every key touched still holds what `expected` gives (absent where it has none), checked in the same
    // step as the write, so an edit made since the read is never written over; false writes nothing.
    func applyToLegacy(puts: [Value], removals: [Key], expected: [Key: Value]) async -> Bool
    // Values the core changed to settle a collision: this Mac's own edits, which sync like any other.
    func announce(settled: [Value]) async
}

internal struct CoreMirrorLegacyRead<Value: Sendable>: Sendable {
    let values: [Value]
    // False while the store holds less than it should: a damaged file set aside and waiting for a refill, or a
    // document that does not read. A record missing from it is then not taken for a deletion.
    let allowsRemovals: Bool
}

internal struct CoreMirrorCoreRead<Value: Sendable>: Sendable {
    let values: [Value]
    let digest: String
}

internal enum CoreMirrorError: Error {
    case outdated
}

internal actor CoreMirror<Adapter: CoreMirrorAdapter> {
    private typealias Side = [String: (key: Adapter.Key, value: Adapter.Value)]

    private static var logger: Logger { Logger(subsystem: "com.TablePro", category: "CoreMirror") }

    nonisolated internal let adapter: Adapter
    private let defaults: UserDefaults
    private var tail: Task<Bool, Never>?
    // A push asked for and not started yet already covers every write before it starts.
    private var waiting = false

    internal init(adapter: Adapter, defaults: UserDefaults) {
        self.adapter = adapter
        self.defaults = defaults
    }

    nonisolated internal var baseKey: String {
        "com.TablePro.coreMirror.\(adapter.name)"
    }

    nonisolated internal func schedulePush() {
        Task { await self.requestPush() }
    }

    private func requestPush() async {
        guard !waiting else { return }
        await push()
    }

    // Runs after every push asked for before it, so a write is never compared against an older one's result. False
    // when the core could not be read or refused the write, so the two may still differ.
    @discardableResult
    internal func push() async -> Bool {
        waiting = true
        let previous = tail
        let run = Task { [self] in
            _ = await previous?.value
            return await pushOnce()
        }
        tail = run
        return await run.value
    }

    // Each record's key, encoded, with the digest of the value both sides held when they last agreed. Nil before the
    // first push.
    internal var base: [String: String]? {
        guard let data = defaults.data(forKey: baseKey) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private func save(_ base: [String: String]) {
        guard let data = try? JSONEncoder().encode(base) else { return }
        defaults.set(data, forKey: baseKey)
    }

    private func pushOnce() async -> Bool {
        waiting = false
        guard let legacy = await adapter.readLegacy() else { return false }
        let core: CoreMirrorCoreRead<Adapter.Value>
        do {
            core = try await adapter.readCore()
        } catch {
            log("the core could not be read", error)
            return false
        }
        let mine = side(legacy.values)
        let theirs = side(core.values)
        guard let base else {
            return await moveIn(legacy, mine: mine, core: core, theirs: theirs)
        }
        var toCore: [Adapter.Value] = []
        var coreRemovals: [Adapter.Key] = []
        var toLegacy: [Adapter.Value] = []
        var legacyRemovals: [Adapter.Key] = []
        for code in Set(mine.keys).union(theirs.keys).union(base.keys) {
            let held = mine[code]
            let copy = theirs[code]
            let legacyChanged = (held != nil || legacy.allowsRemovals) && digest(held?.value) != base[code]
            let coreChanged = digest(copy?.value) != base[code]
            // A record both sides changed takes the Swift store's version, which the person last saw.
            if legacyChanged {
                if let held, held.value != copy?.value {
                    toCore.append(held.value)
                } else if held == nil, let copy {
                    coreRemovals.append(copy.key)
                }
            } else if coreChanged {
                if let copy, copy.value != held?.value {
                    toLegacy.append(copy.value)
                } else if copy == nil, let held {
                    legacyRemovals.append(held.key)
                }
            }
        }
        let refused: Set<String>
        do {
            refused = try await send(puts: toCore, removals: coreRemovals)
        } catch {
            log("the core refused the write", error)
            return false
        }
        var current = mine
        if !toLegacy.isEmpty || !legacyRemovals.isEmpty {
            let unchanged = expected(mine, toLegacy, legacyRemovals)
            if await adapter.applyToLegacy(puts: toLegacy, removals: legacyRemovals, expected: unchanged) {
                apply(toLegacy, legacyRemovals, to: &current)
            } else {
                Self.logger.notice("\(self.adapter.name, privacy: .public): the store changed during the push; the next one takes it")
            }
        }
        return await settle(written: toCore, refused: refused, base: base, current: current, before: theirs)
            && refused.isEmpty
    }

    // The first push: the core comes to hold exactly the Swift store, refused when the core moved since the read.
    private func moveIn(
        _ legacy: CoreMirrorLegacyRead<Adapter.Value>,
        mine: Side,
        core: CoreMirrorCoreRead<Adapter.Value>,
        theirs: Side
    ) async -> Bool {
        var refused: Set<String> = []
        do {
            try await moveWhole(legacy, core: core)
        } catch CoreMirrorError.outdated {
            Self.logger.notice("\(self.adapter.name, privacy: .public): the core changed during the first push; the next one tries again")
            return false
        } catch {
            // A record the core refuses fails the whole write, which then goes one record at a time. The core
            // matched the read when it refused, so removing what the read saw removes nothing newer. A store that
            // holds less than it should removes nothing.
            let puts = legacy.values.filter { theirs[code(of: $0)]?.value != $0 }
            let removals = legacy.allowsRemovals ? theirs.filter { mine[$0.key] == nil }.map(\.value.key) : []
            do {
                refused = try await send(puts: puts, removals: removals)
            } catch {
                log("the core refused the first push", error)
                return false
            }
        }
        return await settle(written: legacy.values, refused: refused, base: [:], current: mine, before: theirs)
            && refused.isEmpty
    }

    private func moveWhole(_ legacy: CoreMirrorLegacyRead<Adapter.Value>, core: CoreMirrorCoreRead<Adapter.Value>) async throws {
        guard legacy.allowsRemovals else { throw CoreMirrorPartialStore() }
        try await adapter.replaceCore(expected: core.digest, values: legacy.values)
    }

    // Returns the encoded keys the core refused; their older copy may still be there, so none reads as a settlement.
    private func send(puts: [Adapter.Value], removals: [Adapter.Key]) async throws -> Set<String> {
        guard !puts.isEmpty || !removals.isEmpty else { return [] }
        do {
            try await adapter.writeCore(puts: puts, removals: removals)
            return []
        } catch {
            // One record the core refuses, such as a blank name, keeps the others out of a single write. Removals go
            // first, so a name or keyword a removed record held is free for the record that takes it.
            if !removals.isEmpty {
                try await adapter.writeCore(puts: [], removals: removals)
            }
            var refused: Set<String> = []
            for value in puts {
                do {
                    try await adapter.writeCore(puts: [value], removals: [])
                } catch {
                    refused.insert(code(of: value))
                }
            }
            if !refused.isEmpty {
                Self.logger.error("\(self.adapter.name, privacy: .public): the core refused \(refused.count, privacy: .public) records")
            }
            return refused
        }
    }

    // A record the core holds differently after a write, one the write carried or one both sides held alike before
    // it, is the core's settlement of a collision, which the Swift store takes and syncs as its own edit. A key both
    // sides now hold alike is agreed; any other keeps its last agreement, so the next push looks at it again.
    private func settle(
        written: [Adapter.Value],
        refused: Set<String>,
        base: [String: String],
        current: Side,
        before: Side
    ) async -> Bool {
        let after: CoreMirrorCoreRead<Adapter.Value>
        do {
            after = try await adapter.readCore()
        } catch {
            log("the core could not be read back", error)
            return false
        }
        let held = side(after.values)
        var current = current
        let carried = Set(written.map(code(of:)))
        let settled: [Adapter.Value] = held.compactMap { encoded, copy in
            guard !refused.contains(encoded), let mine = current[encoded], copy.value != mine.value else { return nil }
            guard carried.contains(encoded) || before[encoded]?.value == mine.value else { return nil }
            return copy.value
        }
        if !settled.isEmpty {
            if await adapter.applyToLegacy(puts: settled, removals: [], expected: expected(current, settled, [])) {
                apply(settled, [], to: &current)
                await adapter.announce(settled: settled)
            } else {
                Self.logger.notice("\(self.adapter.name, privacy: .public): the store changed during the push; the next one takes it")
            }
        }
        var next: [String: String] = [:]
        for code in Set(current.keys).union(held.keys).union(base.keys) {
            let mine = current[code]?.value
            let theirs = held[code]?.value
            if !refused.contains(code), mine == theirs {
                if let agreed = digest(mine) {
                    next[code] = agreed
                }
            } else if let previous = base[code] {
                next[code] = previous
            }
        }
        save(next)
        return true
    }

    private func side(_ values: [Adapter.Value]) -> Side {
        var side: Side = [:]
        for value in values {
            side[code(of: value)] = (adapter.key(of: value), value)
        }
        return side
    }

    private func apply(_ puts: [Adapter.Value], _ removals: [Adapter.Key], to side: inout Side) {
        for key in removals {
            side[Self.encoded(key)] = nil
        }
        for value in puts {
            side[code(of: value)] = (adapter.key(of: value), value)
        }
    }

    // What the read held for each key a write back touches.
    private func expected(_ side: Side, _ puts: [Adapter.Value], _ removals: [Adapter.Key]) -> [Adapter.Key: Adapter.Value] {
        var expected: [Adapter.Key: Adapter.Value] = [:]
        for key in puts.map(adapter.key(of:)) + removals {
            expected[key] = side[Self.encoded(key)]?.value
        }
        return expected
    }

    private func code(of value: Adapter.Value) -> String {
        Self.encoded(adapter.key(of: value))
    }

    private func digest(_ value: Adapter.Value?) -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encoded(_ key: Adapter.Key) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(key) else { return "" }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private func log(_ what: String, _ error: any Error) {
        Self.logger.error("\(self.adapter.name, privacy: .public): \(what, privacy: .public): \(LogRedaction.publicDescription(of: error), privacy: .public)")
    }
}

// A store that holds less than it should never replaces the core's whole copy.
private struct CoreMirrorPartialStore: Error {}
