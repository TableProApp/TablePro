//
//  RedisDatabaseTarget.swift
//  RedisDriverPlugin
//
//  A Redis connection reads whichever numbered database its session last selected, while the
//  app addresses each database as its own table. So a read the app makes for one row goes to that
//  row's database and returns the session to where it was, and a move the session is already past
//  sends nothing: a read-only ACL user is refused SELECT even for the database it is on.
//

import Foundation
import os
import TableProPluginKit

private let logger = Logger(subsystem: "com.TablePro.RedisDriver", category: "RedisDatabaseTarget")

enum RedisDatabaseTarget {
    typealias Statement = (statement: String, parameters: [PluginCellValue])

    /// A grid's writes belong to the database its rows came from, which the session is not on
    /// when the user moved it elsewhere. Run inside the save's `MULTI`, the SELECTs are queued
    /// with the writes and applied together by `EXEC`, which leaves the session where it was.
    /// Without one, as on a cluster, a SELECT sent first stays in force when a write after it
    /// fails, so each write names its database and the session never leaves where it belongs.
    static func addressing(
        _ statements: [Statement],
        toDatabase index: Int?,
        from home: Int,
        insideTransaction: Bool
    ) -> [Statement] {
        guard let index, index != home, !statements.isEmpty else { return statements }
        guard insideTransaction else {
            return statements.map { (statement: "DB \(index) \($0.statement)", parameters: $0.parameters) }
        }
        return [(statement: "SELECT \(index)", parameters: [])]
            + statements
            + [(statement: "SELECT \(home)", parameters: [])]
    }
}

extension RedisCommandChannel {
    func moveToDatabase(_ index: Int) async throws {
        guard databaseForNextCommand() != index || homeDatabase() != index else { return }
        try await selectDatabase(index, scope: .outsideBlock)
    }

    /// Everything the body sends runs on `index`, and the session returns to where it belongs
    /// afterwards, even when the body throws. A refused SELECT throws before the body runs.
    func withDatabase<T>(_ index: Int?, _ body: () async throws -> T) async throws -> T {
        guard let index else { return try await body() }
        let home = homeDatabase()
        return try await RedisDatabaseVisit.$database.withValue(index) {
            guard index != databaseForNextCommand() else { return try await body() }
            try await visitDatabase(index)
            do {
                let value = try await body()
                await returnToDatabase(home)
                return value
            } catch {
                await returnToDatabase(home)
                throw error
            }
        }
    }

    /// Exact for the database the session belongs on. Any other comes from `INFO keyspace`, which
    /// is nil when the server declines it and zero for a database it does not list.
    func keyCount(inDatabase index: Int) async throws -> Int? {
        if index == homeDatabase() {
            return try await runMetadataRead(["DBSIZE"])?.intValue
        }
        guard supportsDatabaseSelection, let counts = try await keyCountsByDatabase() else { return nil }
        return counts[index] ?? 0
    }

    private func returnToDatabase(_ origin: Int) async {
        do {
            try await visitDatabase(origin)
        } catch {
            logger.warning("Could not return the session to database \(origin, privacy: .public)")
        }
    }
}
