//
//  MSSQLFreeTDSConfigFile.swift
//  TableProMSSQLCore
//

import Foundation

/// The freetds.conf every SQL Server connection in the process reads, named to db-lib once with dbsetifile.
///
/// libtds reads the file when dbopen starts, so an entry is held for exactly as long as one dbopen. Entries for
/// different host names sit side by side, and a connection never waits on one to another host name, however long that
/// server takes to answer. libtds applies every section whose name matches, whatever its case, so two connections that
/// describe one host name differently, with another port or another mode, cannot both be in the file: the second waits
/// until the first dbopen returns. Every
/// change replaces the file whole, which leaves a dbopen that already opened it reading the version it opened, and the
/// file is removed once nothing holds an entry.
public final class MSSQLFreeTDSConfigFile: @unchecked Sendable {
    public let path: String

    private let condition = NSCondition()
    private var leases: [String: Lease] = [:]

    private struct Lease {
        let entry: MSSQLFreeTDSServerEntry
        var holders: Int
    }

    public init(path: String) {
        self.path = path
    }

    public func withEntry<T>(_ entry: MSSQLFreeTDSServerEntry, _ body: () throws -> T) throws -> T {
        try acquire(entry)
        defer { release(entry) }
        return try body()
    }

    private static func key(for entry: MSSQLFreeTDSServerEntry) -> String {
        entry.name.lowercased()
    }

    private func acquire(_ entry: MSSQLFreeTDSServerEntry) throws {
        let key = Self.key(for: entry)
        condition.lock()
        defer { condition.unlock() }
        while let lease = leases[key], lease.entry != entry {
            condition.wait()
        }
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
            condition.broadcast()
            throw error
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
