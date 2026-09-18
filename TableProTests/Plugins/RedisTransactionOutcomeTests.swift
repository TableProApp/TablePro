//
//  RedisTransactionOutcomeTests.swift
//  TableProTests
//
//  EXEC puts a command's failure in its own element of the reply array and applies every other
//  command in the block anyway, so a caller reading only the top level reported success for a save
//  the server half refused. A grid save whose RENAME named a missing key answered +OK and wrote the
//  SET that followed it.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Redis transaction outcome")
struct RedisTransactionOutcomeTests {
    /// The shape measured on Redis 8.10.1 for `MULTI; GET s; LPUSH s x; SET t 1; DEL nokey; INCR s;
    /// EXEC`, which then left `GET t` answering 1.
    static let mixedReply = RedisReply.array([
        .string("hello"),
        .error("WRONGTYPE Operation against a key holding the wrong kind of value"),
        .status("OK"),
        .integer(0),
        .error("ERR value is not an integer or out of range"),
    ])

    @Test("Each failed element is named by the command queued at its position")
    func namesEachFailure() {
        let failures = RedisTransactionOutcome.failures(
            inExecReply: Self.mixedReply,
            queuedCommands: ["GET", "LPUSH", "SET", "DEL", "INCR"]
        )
        #expect(failures == [
            RedisFailedCommand(
                label: "LPUSH",
                message: "WRONGTYPE Operation against a key holding the wrong kind of value"
            ),
            RedisFailedCommand(label: "INCR", message: "ERR value is not an integer or out of range"),
        ])
    }

    @Test("A block the server applied without complaint names nothing")
    func cleanBlockHasNoFailures() {
        let reply = RedisReply.array([.status("OK"), .integer(1)])
        #expect(RedisTransactionOutcome.failures(inExecReply: reply, queuedCommands: ["SET", "DEL"]).isEmpty)
        #expect(RedisTransactionOutcome.failures(inExecReply: .array([]), queuedCommands: []).isEmpty)
    }

    /// `-EXECABORT` for a queue-time refusal, `-ERR EXEC without MULTI` after a `RESET`, and a nil
    /// reply for a broken `WATCH` all mean nothing ran, and `throwIfError` already raises the first
    /// two.
    @Test(
        "A reply that is not an array is a block that never ran",
        arguments: [
            RedisReply.error("EXECABORT Transaction discarded because of previous errors."),
            RedisReply.error("ERR EXEC without MULTI"),
            RedisReply.null,
            RedisReply.status("OK"),
            RedisReply.integer(0),
        ]
    )
    func nonArrayRepliesNameNothing(reply: RedisReply) {
        #expect(RedisTransactionOutcome.failures(inExecReply: reply, queuedCommands: ["SET"]).isEmpty)
    }

    /// A user is free to type their own `MULTI` on the same session, so the block can hold commands
    /// the driver never recorded.
    @Test("A position with no recorded command is named by its position")
    func fallsBackToPositions() {
        let reply = RedisReply.array([.status("OK"), .error("ERR no such key"), .error("ERR nope")])
        let failures = RedisTransactionOutcome.failures(inExecReply: reply, queuedCommands: ["SET", ""])
        #expect(failures.map(\.label) == ["Command 2", "Command 3"])
    }

    @Test("One failure reads as one command, several read as a list")
    func presentsFailuresToTheApp() {
        let one = RedisTransactionError(failed: [RedisFailedCommand(label: "RENAME", message: "ERR no such key")])
        #expect(one.pluginErrorMessage.contains("RENAME"))
        #expect(one.pluginErrorMessage.contains("ERR no such key"))

        let two = RedisTransactionError(failed: [
            RedisFailedCommand(label: "RENAME", message: "ERR no such key"),
            RedisFailedCommand(label: "INCR", message: "ERR value is not an integer or out of range"),
        ])
        #expect(two.pluginErrorMessage.contains("RENAME"))
        #expect(two.pluginErrorMessage.contains("INCR"))
        #expect(two.pluginErrorMessage.contains("2"))
        #expect(two.pluginErrorDetail?.isEmpty == false)
    }
}

@Suite("Redis queued database")
struct RedisQueuedDatabaseTests {
    @Test("A block that applied moves the session to the queued index")
    func execAdoptsThePendingIndex() {
        var queued = RedisQueuedDatabase()
        queued.queue(2)
        #expect(queued.resolve(command: "EXEC", reply: .array([.status("OK")])) == 2)
        #expect(queued.pending == nil)
    }

    struct EndedBlock: Sendable {
        let command: String
        let reply: RedisReply
    }

    /// Measured: `MULTI; SELECT 2; DISCARD` and `MULTI; SELECT 3; RESET` both leave `CLIENT INFO`
    /// reporting `db=0`.
    static let endedBlocks: [EndedBlock] = [
        EndedBlock(command: "DISCARD", reply: .status("OK")),
        EndedBlock(command: "RESET", reply: .status("RESET")),
        EndedBlock(command: "EXEC", reply: .error("EXECABORT Transaction discarded because of previous errors.")),
        EndedBlock(command: "EXEC", reply: .error("ERR EXEC without MULTI")),
        EndedBlock(command: "EXEC", reply: .null),
    ]

    @Test("A block that never ran leaves the session where it was", arguments: endedBlocks)
    func endedBlockDropsThePendingIndex(block: EndedBlock) {
        var queued = RedisQueuedDatabase()
        queued.queue(2)
        #expect(queued.resolve(command: block.command, reply: block.reply) == nil)
        #expect(queued.pending == nil)
    }

    @Test("A command name is read case-insensitively, the way redis-cli accepts one")
    func commandNameIsCaseInsensitive() {
        var queued = RedisQueuedDatabase()
        queued.queue(4)
        #expect(queued.resolve(command: "exec", reply: .array([.status("OK")])) == 4)
    }

    @Test("Any other command inside the block leaves the queued index waiting")
    func otherCommandsKeepThePendingIndex() {
        var queued = RedisQueuedDatabase()
        queued.queue(2)
        #expect(queued.resolve(command: "SET", reply: .status("QUEUED")) == nil)
        #expect(queued.resolve(command: "GET", reply: .status("QUEUED")) == nil)
        #expect(queued.pending == 2)
    }

    /// `MULTI` inside an open block is refused and leaves the block open, so it cannot be read as
    /// the block ending. Measured: `ERR MULTI calls can not be nested`.
    @Test("A refused nested MULTI keeps the queued index")
    func nestedMultiKeepsThePendingIndex() {
        var queued = RedisQueuedDatabase()
        queued.queue(2)
        #expect(queued.resolve(command: "MULTI", reply: .error("ERR MULTI calls can not be nested")) == nil)
        #expect(queued.pending == 2)
    }

    @Test("A MULTI the server accepted starts a block with nothing pending in it")
    func acceptedMultiClearsThePendingIndex() {
        var queued = RedisQueuedDatabase()
        queued.queue(2)
        #expect(queued.resolve(command: "MULTI", reply: .status("OK")) == nil)
        #expect(queued.pending == nil)
    }

    @Test("Nothing is adopted when no SELECT was queued")
    func execWithoutAPendingIndexAdoptsNothing() {
        var queued = RedisQueuedDatabase()
        #expect(queued.resolve(command: "EXEC", reply: .array([.status("OK")])) == nil)
        #expect(queued.resolve(command: nil, reply: .array([.status("OK")])) == nil)
    }

    @Test("Clearing it drops the queued index, which is what a lost connection does")
    func clearingDropsThePendingIndex() {
        var queued = RedisQueuedDatabase()
        queued.queue(7)
        queued.clear()
        #expect(queued.pending == nil)
        #expect(queued.resolve(command: "EXEC", reply: .array([.status("OK")])) == nil)
    }
}
