//
//  RedisConditionalWriteTests.swift
//  RedisDriverTests
//

import Foundation
import TableProPluginKit
import Testing

struct RedisConditionalWriteTests {
    private func valueEdit(originalTTL: PluginCellValue, alsoSettingTTL ttl: PluginCellValue? = nil) -> PluginRowChange {
        var cells: [(columnIndex: Int, columnName: String, oldValue: PluginCellValue, newValue: PluginCellValue)] = [
            (columnIndex: 1, columnName: "Value", oldValue: "old", newValue: "new")
        ]
        if let ttl {
            cells.append((columnIndex: 2, columnName: "TTL", oldValue: originalTTL, newValue: ttl))
        }
        return PluginRowChange(
            rowIndex: 0, type: .update, cellChanges: cells, originalRow: ["session:abc", "old", originalTTL]
        )
    }

    private func statements(_ change: PluginRowChange, keepsTTLOnSet: Bool) throws -> [String] {
        let generator = RedisStatementGenerator(
            namespaceName: "", columns: ["Key", "Value", "TTL"], keepsTTLOnSet: keepsTTLOnSet
        )
        return try generator.generateRowWrites(
            from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        ).map(\.statement)
    }

    @Test("A value edit on a key with a TTL keeps the TTL")
    func valueEditKeepsTTL() throws {
        #expect(try statements(valueEdit(originalTTL: "1800"), keepsTTLOnSet: true) == ["SET session:abc new KEEPTTL"])
    }

    @Test("A server older than 6.0 gets the expiry put back after the SET")
    func legacyServerRestoresTTL() throws {
        #expect(try statements(valueEdit(originalTTL: "1800"), keepsTTLOnSet: false)
            == ["SET session:abc new", "EXPIRE session:abc 1800"])
        #expect(try statements(valueEdit(originalTTL: "-1"), keepsTTLOnSet: false) == ["SET session:abc new"])
        #expect(try statements(valueEdit(originalTTL: "1800", alsoSettingTTL: "60"), keepsTTLOnSet: false)
            == ["SET session:abc new", "EXPIRE session:abc 60"])
    }

    @Test("KEEPTTL is used from Redis 6.0 and when the version is unknown")
    func keepTTLByVersion() {
        #expect(RedisStatementGenerator.serverKeepsTTLOnSet(version: "7.2.4"))
        #expect(RedisStatementGenerator.serverKeepsTTLOnSet(version: "6.0.0"))
        #expect(RedisStatementGenerator.serverKeepsTTLOnSet(version: nil))
        #expect(!RedisStatementGenerator.serverKeepsTTLOnSet(version: "5.0.14"))
    }

    @Test("A reply of 0 or nil says the conditional write did nothing")
    func appliedReadsTheReply() {
        #expect(!RedisConditionalWrite.applied(.integer(0)))
        #expect(!RedisConditionalWrite.applied(.null))
        #expect(RedisConditionalWrite.applied(.integer(1)))
        #expect(RedisConditionalWrite.applied(.status("OK")))
    }

    @Test("EXEC names a rename or insert the server skipped because the key exists")
    func execReportsSkippedConditionalWrites() {
        let reply = RedisReply.array([.status("OK"), .integer(0), .null, .integer(0), .integer(1)])
        let queued = ["SET", "RENAMENX", "SET", "DEL", "RENAMENX"]
        let failures = RedisTransactionOutcome.failures(
            inExecReply: reply, queuedCommands: queued, conditionalPositions: [1, 2, 4]
        )
        #expect(failures == [
            RedisFailedCommand(label: "RENAMENX", message: RedisConditionalWrite.refusedMessage),
            RedisFailedCommand(label: "SET", message: RedisConditionalWrite.refusedMessage),
        ])
    }

    @Test("A skipped conditional write past the recorded labels still fails the save")
    func execReportsSkippedWritePastTheLabelCap() {
        let reply = RedisReply.array([.status("OK"), .integer(0)])
        let failures = RedisTransactionOutcome.failures(
            inExecReply: reply, queuedCommands: ["SET"], conditionalPositions: [1]
        )
        #expect(failures.count == 1)
        #expect(failures.first?.message == RedisConditionalWrite.refusedMessage)
    }

    private func driver() -> RedisPluginDriver {
        RedisPluginDriver(config: DriverConnectionConfig(
            host: "127.0.0.1", port: 6_379, username: "", password: "", database: "0"
        ))
    }

    @Test("A rename onto an existing key fails the statement, and the wrapper is not sent")
    func refusedRenameThrows() async throws {
        let channel = StubRedisChannel([.integer(0)])
        await #expect(throws: RedisPluginError.self) {
            _ = try await driver().executeOperation(
                try RedisCommandParser.parse("MUSTAPPLY RENAMENX old new"), connection: channel, startTime: Date()
            )
        }
        #expect(channel.sentCommands == [["RENAMENX", "old", "new"]])
    }

    // Outside a block the save stops at the failed statement, so the DEL after the rename never runs.
    @Test("A staged insert refused because the key exists drops its staging key")
    func refusedStagedInsertDropsItsStagingKey() async throws {
        let driver = self.driver()
        let staging = "queue:tablepro-staging:\(driver.issueStagingToken())"
        let channel = StubRedisChannel([.integer(0), .integer(1)])
        await #expect(throws: RedisPluginError.self) {
            _ = try await driver.executeOperation(
                try RedisCommandParser.parse("MUSTAPPLY RENAMENX \(staging) queue"), connection: channel, startTime: Date()
            )
        }
        #expect(channel.sentCommands == [["RENAMENX", staging, "queue"], ["DEL", staging]])
        #expect(channel.sentScopes.last == .outsideBlock)
    }

    @Test("A staged rename the server answers with an error drops its staging key")
    func failedStagedRenameDropsItsStagingKey() async throws {
        let driver = self.driver()
        let staging = "queue:tablepro-staging:\(driver.issueStagingToken())"
        let channel = StubRedisChannel(outcomes: [
            .failure(RedisPluginError(code: 0, message: "NOPERM No permissions to access a key")),
            .success(.integer(1))
        ])
        await #expect(throws: RedisPluginError.self) {
            _ = try await driver.executeOperation(
                try RedisCommandParser.parse("MUSTAPPLY RENAMENX \(staging) queue"), connection: channel, startTime: Date()
            )
        }
        #expect(channel.sentCommands == [["RENAMENX", staging, "queue"], ["DEL", staging]])
    }

    @Test("A refused expiry on a staging key drops it before the save stops")
    func failedStagingExpiryDropsItsStagingKey() async throws {
        let driver = self.driver()
        let staging = "queue:tablepro-staging:\(driver.issueStagingToken())"
        let channel = StubRedisChannel(outcomes: [
            .failure(RedisPluginError(code: 0, message: "NOPERM this user has no permissions to run the 'expire' command")),
            .success(.integer(1))
        ])
        await #expect(throws: RedisPluginError.self) {
            _ = try await driver.executeOperation(
                try RedisCommandParser.parse("EXPIRE \(staging) 60"), connection: channel, startTime: Date()
            )
        }
        #expect(channel.sentCommands == [["EXPIRE", staging, "60"], ["DEL", staging]])
    }

    // A leftover staging key shows in the grid, and renaming it onto a taken name must not delete it.
    @Test("A refused rename of a staging key this driver did not generate keeps it")
    func refusedRenameOfALeftoverKeepsIt() async throws {
        let channel = StubRedisChannel([.integer(0)])
        await #expect(throws: RedisPluginError.self) {
            _ = try await driver().executeOperation(
                try RedisCommandParser.parse("MUSTAPPLY RENAMENX queue:tablepro-staging:old queue"),
                connection: channel,
                startTime: Date()
            )
        }
        #expect(channel.sentCommands == [["RENAMENX", "queue:tablepro-staging:old", "queue"]])
    }

    @Test("A staged insert onto a free name leaves nothing to drop")
    func appliedStagedInsertSendsNoDelete() async throws {
        let driver = self.driver()
        let staging = "queue:tablepro-staging:\(driver.issueStagingToken())"
        let channel = StubRedisChannel([.integer(1)])
        _ = try await driver.executeOperation(
            try RedisCommandParser.parse("MUSTAPPLY RENAMENX \(staging) queue"), connection: channel, startTime: Date()
        )
        #expect(channel.sentCommands == [["RENAMENX", staging, "queue"]])
    }

    @Test("A rename onto a free name succeeds")
    func appliedRenameSucceeds() async throws {
        let channel = StubRedisChannel([.integer(1)])
        let result = try await driver().executeOperation(
            try RedisCommandParser.parse("MUSTAPPLY RENAMENX old new"), connection: channel, startTime: Date()
        )
        #expect(result.rows.first?.first?.asText == "OK")
    }

    @Test("A SET that NX or XX kept from writing shows nil, as the server answered")
    func skippedSetShowsNil() async throws {
        let channel = StubRedisChannel([.null])
        let result = try await driver().executeOperation(
            try RedisCommandParser.parse("SET lock:job 1 NX"), connection: channel, startTime: Date()
        )
        #expect(result.rows.first?.first?.asText == "(nil)")
        #expect(channel.sentCommands == [["SET", "lock:job", "1", "NX"]])
    }

    @Test("A SET that wrote the key shows OK")
    func appliedSetShowsOK() async throws {
        let channel = StubRedisChannel([.status("OK")])
        let result = try await driver().executeOperation(
            try RedisCommandParser.parse("SET lock:job 1 XX EX 60"), connection: channel, startTime: Date()
        )
        #expect(result.rows.first?.first?.asText == "OK")
    }

    @Test("A conditional write the server refused outright keeps the server's message")
    func execKeepsServerErrorForConditionalWrite() {
        let reply = RedisReply.array([.error("ERR no such key")])
        let failures = RedisTransactionOutcome.failures(
            inExecReply: reply, queuedCommands: ["RENAMENX"], conditionalPositions: [0]
        )
        #expect(failures == [RedisFailedCommand(label: "RENAMENX", message: "ERR no such key")])
    }
}
