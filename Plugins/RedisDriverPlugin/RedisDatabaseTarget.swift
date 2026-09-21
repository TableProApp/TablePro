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

private let logger = Logger(subsystem: "com.TablePro.RedisDriver", category: "RedisDatabaseTarget")

extension RedisCommandChannel {
    func moveToDatabase(_ index: Int) async throws {
        guard databaseForNextCommand() != index else { return }
        try await selectDatabase(index, scope: .outsideBlock)
    }

    /// The session is put back even when the body throws, so a failed read never leaves the
    /// sidebar and the key tree reading another database. A refused SELECT throws before the body.
    func withDatabase<T>(_ index: Int?, _ body: () async throws -> T) async throws -> T {
        let origin = databaseForNextCommand()
        guard let index, index != origin else { return try await body() }
        try await selectDatabase(index, scope: .outsideBlock)
        do {
            let value = try await body()
            await returnToDatabase(origin)
            return value
        } catch {
            await returnToDatabase(origin)
            throw error
        }
    }

    /// Exact for the database the session is on. Any other comes from `INFO keyspace`, which is
    /// nil when the server declines it and zero for a database it does not list.
    func keyCount(inDatabase index: Int) async throws -> Int? {
        if index == databaseForNextCommand() {
            return try await runMetadataRead(["DBSIZE"])?.intValue
        }
        guard supportsDatabaseSelection, let counts = try await keyCountsByDatabase() else { return nil }
        return counts[index] ?? 0
    }

    private func returnToDatabase(_ origin: Int) async {
        do {
            try await selectDatabase(origin, scope: .outsideBlock)
        } catch {
            logger.warning("Could not return the session to database \(origin, privacy: .public)")
        }
    }
}
