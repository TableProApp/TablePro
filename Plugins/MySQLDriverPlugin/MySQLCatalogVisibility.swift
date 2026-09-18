//
//  MySQLCatalogVisibility.swift
//  MySQLDriverPlugin
//
//  Whether `information_schema` on this connection describes a given database, and the rule that
//  decides it from reads the driver already makes.
//

import Foundation

/// A MySQL-protocol proxy answers `information_schema` from its own configuration rather than from
/// the database the caller named, so the catalog can be authoritative for one database on a
/// connection and say nothing at all about the next.
internal enum MySQLCatalogVisibility: Equatable, Sendable {
    /// The catalog answers for this database, so a whole-schema read is one statement.
    case describes
    /// The catalog answers nothing or refuses, and the `SHOW` statements tell the truth instead.
    case blind
}

/// What a catalog read answered, which is three things and not two.
///
/// A server that refuses has said nothing about the database: the statement may simply have hit the
/// query timeout. A server that answers a scalar aggregate with no row at all has said something,
/// because a direct server always answers one row.
internal enum MySQLCatalogCount: Equatable, Sendable {
    /// The catalog answered, with this many tables.
    case counted(Int)
    /// The read succeeded and carried no row, or no number. Measured on DBLE 3.23.
    case noRow
    /// The server refused the read, so nothing was learned from it.
    case refused
}

/// What one round of probing learned, which the verdict alone cannot carry: a refused read is not a
/// pair of answers that failed to agree.
internal enum MySQLCatalogProbe: Equatable, Sendable {
    case settled(MySQLCatalogVisibility)
    /// Both reads answered and neither settles it, so the catalog's own answer stands.
    case unsettled
    /// A read the server refused. Nothing is recorded, and the caller falls back for this call only.
    case refused
}

internal enum MySQLCatalogVisibilityRule {
    /// Nil where neither read settles it, which is not the same as blind.
    ///
    /// Three answers are genuinely ambiguous and must stay uncached. A database with no tables reads
    /// as zero from both. An account that may list a database but not open it gets an empty catalog
    /// answer and `ERROR 1044` from `SHOW FULL TABLES`, measured in #2950 and again on MySQL 8.4.11,
    /// where an account holding only the global `SHOW DATABASES` privilege answers one row of `0`
    /// from the count and `ERROR 1044` from the `SHOW`: recording that as blind would turn every
    /// later whole-schema read there into one failing `SHOW` per table. And a read the server refused
    /// teaches nothing at all, because a refusal is not the catalog disowning the database: the query
    /// timeout, or a driver reaching the wrong object, refuses the same way.
    ///
    /// `listedTables` is nil where `SHOW FULL TABLES` was refused or was never asked.
    static func verdict(count: MySQLCatalogCount, listedTables: Int?) -> MySQLCatalogVisibility? {
        switch count {
        case .refused:
            return nil
        case .noRow:
            return .blind
        case .counted(let catalogRows):
            guard catalogRows == 0 else { return .describes }
            guard let listedTables else { return nil }
            return listedTables > 0 ? .blind : nil
        }
    }

    /// A server error says the catalog cannot answer for this database. A client error says the
    /// connection failed, which the `SHOW` fallback would fail at too.
    static func settlesBlindness(code: UInt32) -> Bool {
        MySQLTableListing.showFullTablesSettlesCatalogFailure(code: code)
    }
}

/// One verdict per database, for the lifetime of a server session.
///
/// It has a lock of its own rather than joining the driver's `sessionLock`, because it is read on
/// the path of every metadata statement and holds nothing that decides whether a connection may be
/// released.
internal final class MySQLCatalogVisibilityLedger: @unchecked Sendable {
    private var verdicts: [String: MySQLCatalogVisibility] = [:]
    private let lock = NSLock()

    internal init() {}

    internal func visibility(of database: String) -> MySQLCatalogVisibility? {
        lock.withLock { verdicts[database] }
    }

    internal func record(_ visibility: MySQLCatalogVisibility, for database: String) {
        lock.withLock { verdicts[database] = visibility }
    }

    /// A blind mark is a guess taken from one failed read, so the fallback failing too withdraws
    /// it rather than leaving the database reading through `SHOW` for the session's life.
    internal func forget(_ database: String) {
        lock.withLock { verdicts[database] = nil }
    }

    internal func clear() {
        lock.withLock { verdicts.removeAll() }
    }
}
