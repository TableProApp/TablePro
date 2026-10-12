//
//  MSSQLFreeTDSConfigFile.swift
//  TableProMSSQLCore
//

import Foundation

/// The freetds.conf every SQL Server connection in the process reads, named to db-lib once with dbsetifile.
///
/// libtds reads the file when dbopen starts, so an entry is held for exactly as long as one dbopen. Entries with
/// different names sit side by side, and a connection never waits on one with another name, however long that server
/// takes to answer. libtds applies every section whose name matches, whatever its case, so two entries that share a
/// name and differ in anything else cannot both be in the file: the later one waits until the dbopen holding the name
/// returns. Connections to one name take it in the order they asked, so identical connections that keep arriving
/// cannot keep a different one waiting for ever. A wait has a limit, and a connection whose caller gave up leaves
/// the line once `interruptWaits` wakes it. Every change replaces the file whole, which leaves a dbopen that already
/// opened it reading the version it opened, and the file is removed once nothing holds an entry.
public final class MSSQLFreeTDSConfigFile: @unchecked Sendable {
    public let path: String

    private let condition = NSCondition()
    private var leases: [String: Lease] = [:]
    private var queues: [String: [Int]] = [:]
    private var nextTicket = 0

    private struct Lease {
        let entry: MSSQLFreeTDSServerEntry
        var holders: Int
    }

    public init(path: String) {
        self.path = path
    }

    public func withEntry<T>(
        _ entry: MSSQLFreeTDSServerEntry,
        waitingAtMost timeout: TimeInterval,
        givingUpWhen isAbandoned: () -> Bool = { false },
        _ body: () throws -> T
    ) throws -> T {
        try acquire(entry, waitingUntil: Date(timeIntervalSinceNow: timeout), givingUpWhen: isAbandoned)
        defer { release(entry) }
        return try body()
    }

    /// Wakes every waiting connection so one whose caller has given up can leave the line.
    public func interruptWaits() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    internal func waitingConnections(named name: String) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return queues[name.lowercased()]?.count ?? 0
    }

    private static func key(for entry: MSSQLFreeTDSServerEntry) -> String {
        entry.name.lowercased()
    }

    private func acquire(
        _ entry: MSSQLFreeTDSServerEntry,
        waitingUntil deadline: Date,
        givingUpWhen isAbandoned: () -> Bool
    ) throws {
        let key = Self.key(for: entry)
        condition.lock()
        defer { condition.unlock() }
        let ticket = nextTicket
        nextTicket += 1
        queues[key, default: []].append(ticket)
        defer {
            leaveQueue(key, ticket: ticket)
            condition.broadcast()
        }
        try waitForTurn(ticket, entry: entry, key: key, until: deadline, givingUpWhen: isAbandoned)
        try hold(entry, key: key)
    }

    private func waitForTurn(
        _ ticket: Int,
        entry: MSSQLFreeTDSServerEntry,
        key: String,
        until deadline: Date,
        givingUpWhen isAbandoned: () -> Bool
    ) throws {
        while !isAdmitted(ticket, entry: entry, key: key) {
            if isAbandoned() {
                throw CancellationError()
            }
            if !condition.wait(until: deadline), !isAdmitted(ticket, entry: entry, key: key) {
                throw MSSQLFreeTDSConfigError.nameInUse(entry.name)
            }
        }
    }

    private func isAdmitted(_ ticket: Int, entry: MSSQLFreeTDSServerEntry, key: String) -> Bool {
        guard queues[key]?.first == ticket else { return false }
        guard let lease = leases[key] else { return true }
        return lease.entry == entry
    }

    private func hold(_ entry: MSSQLFreeTDSServerEntry, key: String) throws {
        if var lease = leases[key] {
            lease.holders += 1
            leases[key] = lease
            return
        }
        leases[key] = Lease(entry: entry, holders: 1)
        do {
            try write()
        } catch {
            leases[key] = nil
            throw error
        }
    }

    private func leaveQueue(_ key: String, ticket: Int) {
        queues[key]?.removeAll { $0 == ticket }
        if queues[key]?.isEmpty == true {
            queues[key] = nil
        }
    }

    private func release(_ entry: MSSQLFreeTDSServerEntry) {
        let key = Self.key(for: entry)
        condition.lock()
        defer { condition.unlock() }
        guard var lease = leases[key] else { return }
        lease.holders -= 1
        guard lease.holders == 0 else {
            leases[key] = lease
            return
        }
        leases[key] = nil
        try? write()
        condition.broadcast()
    }

    private func write() throws {
        guard !leases.isEmpty else {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        let text = leases.keys.sorted().compactMap { leases[$0]?.entry.text }.joined(separator: "\n")
        let staging = path + ".staging"
        guard FileManager.default.createFile(
            atPath: staging,
            contents: Data(text.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw MSSQLFreeTDSConfigError.unwritable(staging)
        }
        guard rename(staging, path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(atPath: staging)
            throw MSSQLFreeTDSConfigError.unwritable(reason)
        }
    }
}
