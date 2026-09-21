//
//  RedisSessionFootprintTests.swift
//  TableProTests
//
//  Every command on a Redis connection shares one server session, so the sidebar's reads, the
//  key tree's scans and the health monitor's PING used to join a MULTI block the user left open:
//  an allowed one added its reply to EXEC, a refused one aborted the block with EXECABORT, and a
//  reconnect replayed into a new session that no longer had the block at all. Each transition
//  here is a reply measured on Redis 8.10.1.
//

import Foundation
import TableProPluginKit
import Testing

private struct Step: Sendable {
    let command: String
    let reply: RedisReply
}

private func footprint(after steps: [Step]) -> RedisSessionFootprint {
    var footprint = RedisSessionFootprint()
    for step in steps {
        _ = footprint.observe(command: step.command, reply: step.reply)
    }
    return footprint
}

private let multi = Step(command: "MULTI", reply: .status("OK"))
private let queuedSet = Step(command: "SET", reply: .status("QUEUED"))
private let watch = Step(command: "WATCH", reply: .status("OK"))

@Suite("Redis session footprint - what a reply leaves on the session")
struct RedisSessionFootprintTests {
    @Test("MULTI opens a block, and a queued command confirms one")
    func multiOpensBlock() {
        #expect(footprint(after: [multi]).hasOpenBlock)
        #expect(footprint(after: [queuedSet]).hasOpenBlock)
    }

    @Test("A refused or nested MULTI leaves the block as it was")
    func refusedMultiChangesNothing() {
        let refused = Step(command: "MULTI", reply: .error("NOPERM User u has no permissions to run the 'multi' command"))
        #expect(!footprint(after: [refused]).hasOpenBlock)

        let nested = Step(command: "multi", reply: .error("ERR MULTI calls can not be nested"))
        #expect(footprint(after: [multi, nested]).hasOpenBlock)
    }

    static let execReplies: [RedisReply] = [
        .array([.status("OK")]),
        .array([]),
        .null,
        .error("EXECABORT Transaction discarded because of previous errors."),
    ]

    @Test("EXEC ends the block and every WATCH whatever it answers", arguments: execReplies)
    func execEndsBlock(reply: RedisReply) {
        let ended = footprint(after: [watch, multi, queuedSet, Step(command: "EXEC", reply: reply)])
        #expect(!ended.hasOpenBlock)
        #expect(!ended.isWatching)
    }

    @Test("EXEC with no block open is refused and keeps the WATCH")
    func execWithoutBlockKeepsWatch() {
        let refused = Step(command: "EXEC", reply: .error("ERR EXEC without MULTI"))
        let after = footprint(after: [watch, refused])
        #expect(after.isWatching)
        #expect(after.heldState == .watchedKeys)
    }

    @Test("DISCARD ends the block and every WATCH, a refused one changes nothing")
    func discard() {
        let ended = footprint(after: [watch, multi, Step(command: "DISCARD", reply: .status("OK"))])
        #expect(!ended.hasOpenBlock)
        #expect(!ended.isWatching)

        let refused = Step(command: "DISCARD", reply: .error("NOPERM User u has no permissions to run the 'discard' command"))
        #expect(footprint(after: [multi, refused]).hasOpenBlock)
    }

    @Test("RESET ends both and moves the session to database 0")
    func reset() {
        var session = footprint(after: [watch, multi])
        let movedTo = session.observe(command: "RESET", reply: .status("RESET"))
        #expect(movedTo == 0)
        #expect(session.heldState == nil)
    }

    @Test("WATCH and UNWATCH follow the server's answer")
    func watchAndUnwatch() {
        #expect(footprint(after: [watch]).isWatching)
        #expect(!footprint(after: [watch, Step(command: "UNWATCH", reply: .status("OK"))]).isWatching)

        let insideBlock = Step(command: "WATCH", reply: .error("ERR WATCH inside MULTI is not allowed"))
        let after = footprint(after: [multi, insideBlock])
        #expect(after.hasOpenBlock)
        #expect(!after.isWatching)
    }

    /// Inside a block every other command answers `QUEUED` or an error, so an ordinary answer
    /// means there is no block, whatever the footprint believed.
    @Test("An ordinary answer means no block is open")
    func ordinaryAnswerClosesBlock() {
        #expect(!footprint(after: [multi, Step(command: "GET", reply: .string("v"))]).hasOpenBlock)
        #expect(footprint(after: [multi, Step(command: "FOO", reply: .error("ERR unknown command 'FOO'"))]).hasOpenBlock)
    }

    @Test("A SELECT queued in a block moves the session only when EXEC runs it")
    func queuedSelect() {
        var session = footprint(after: [multi])
        session.queueDatabase(3)
        #expect(session.observe(command: "EXEC", reply: .array([.status("OK")])) == 3)

        var discarded = footprint(after: [multi])
        discarded.queueDatabase(3)
        #expect(discarded.observe(command: "DISCARD", reply: .status("OK")) == nil)
    }
}

@Suite("Redis session footprint - which commands may be sent")
struct RedisSessionFootprintAdmissionTests {
    @Test("A clean session holds nothing back")
    func cleanSession() {
        let session = RedisSessionFootprint()
        #expect(session.heldBack(.session) == nil)
        #expect(session.heldBack(.outsideBlock) == nil)
        #expect(session.heldBack(.cleanSession) == nil)
    }

    @Test("An open block holds back the app's reads and its transaction, never the user")
    func openBlock() {
        let session = footprint(after: [multi])
        #expect(session.heldBack(.session) == nil)
        #expect(session.heldBack(.outsideBlock) == .openBlock)
        #expect(session.heldBack(.cleanSession) == .openBlock)
    }

    /// A read cannot disturb a WATCH, but the app's own MULTI and EXEC would run under the user's
    /// watched keys and report a discarded save as a success.
    @Test("Watched keys hold back only the app's transaction")
    func watchedKeys() {
        let session = footprint(after: [watch])
        #expect(session.heldBack(.session) == nil)
        #expect(session.heldBack(.outsideBlock) == nil)
        #expect(session.heldBack(.cleanSession) == .watchedKeys)
    }

    @Test("A lost block is latched once and reported once")
    func lossIsReportedOnce() {
        var session = footprint(after: [multi, queuedSet])
        session.sessionEnded()
        #expect(session.heldState == nil)
        #expect(session.takePendingLoss() == .openBlock)
        #expect(session.takePendingLoss() == nil)
    }

    @Test("An open block outranks a WATCH when the session ends")
    func blockOutranksWatch() {
        var session = footprint(after: [watch, multi])
        session.sessionEnded()
        #expect(session.pendingLoss == .openBlock)
    }

    @Test("A session holding nothing latches nothing")
    func cleanSessionLatchesNothing() {
        var session = RedisSessionFootprint()
        session.sessionEnded()
        #expect(session.pendingLoss == nil)
    }

    @Test("A loss handed over from a replaced connection is kept, and not overwritten")
    func adoptLoss() {
        var session = RedisSessionFootprint()
        session.adoptLoss(.watchedKeys)
        session.adoptLoss(.openBlock)
        #expect(session.pendingLoss == .watchedKeys)
        session.adoptLoss(nil)
        #expect(session.pendingLoss == .watchedKeys)
    }
}

@Suite("Redis session footprint - the errors the user reads")
struct RedisSessionFootprintErrorTests {
    @Test("A held-back command names itself and what held it back")
    func heldBackMessages() {
        let block = RedisHeldBackCommand(command: "config", held: .openBlock)
        let watched = RedisHeldBackCommand(command: "MULTI", held: .watchedKeys)
        #expect(block.pluginErrorMessage.contains("CONFIG"))
        #expect(watched.pluginErrorMessage.contains("MULTI"))
        #expect(block.pluginErrorMessage != watched.pluginErrorMessage)
        #expect(block.pluginErrorDetail != watched.pluginErrorDetail)
        #expect(!RedisHeldBackCommand(command: "", held: .openBlock).pluginErrorMessage.hasPrefix(" "))
    }

    @Test("A lost block, a lost EXEC and a lost WATCH each say something different")
    func lossMessages() {
        let messages = [
            RedisSessionStateLost(held: .openBlock, outcomeUnknown: false),
            RedisSessionStateLost(held: .openBlock, outcomeUnknown: true),
            RedisSessionStateLost(held: .watchedKeys, outcomeUnknown: false),
        ].map(\.pluginErrorMessage)
        #expect(Set(messages).count == 3)
    }
}

@Suite("Redis command channel - an open block and the app's own commands")
struct RedisCommandChannelOpenBlockTests {
    @Test("The database listing is held back from an open block and sends nothing")
    func listingHeldBack() async throws {
        let channel = StubRedisChannel([])
        channel.observeOpenBlock()
        await #expect(throws: RedisHeldBackCommand(command: "CONFIG", held: .openBlock)) {
            try await channel.databaseListing(includingKeyCounts: true)
        }
        #expect(channel.sentCommands.isEmpty)
    }

    @Test("The database listing's reads go out as the app's own")
    func listingScopes() async throws {
        let channel = StubRedisChannel([.array([.string("databases"), .string("16")]), .string("# Keyspace\r\n")])
        _ = try await channel.databaseListing(includingKeyCounts: true)
        #expect(channel.sentScopes == [.outsideBlock, .outsideBlock])
    }

    @Test("A command the user types still goes into their block")
    func userCommandJoinsBlock() async throws {
        let channel = StubRedisChannel([.status("QUEUED")])
        channel.observeOpenBlock()
        let reply = try await channel.executeCommand(["SET", "k", "v"])
        #expect(reply.isQueued)
        #expect(channel.sentScopes == [.session])
    }

    @Test("The health probe sends nothing while a block is open and reports healthy")
    func probeHeldBack() async throws {
        let channel = StubRedisChannel([])
        channel.observeOpenBlock()
        try await channel.probeHealth()
        #expect(channel.sentCommands.isEmpty)
    }

    @Test("The health probe still runs while keys are watched")
    func probeRunsWhileWatching() async throws {
        let channel = StubRedisChannel([.status("PONG")])
        channel.observeWatch()
        try await channel.probeHealth()
        #expect(channel.sentCommands == [["PING"]])
    }

    @Test("The health probe fails only a session with no identity")
    func probeOutcomes() async throws {
        try await StubRedisChannel([.error("NOPERM User u has no permissions to run the 'ping' command")]).probeHealth()
        await #expect(throws: RedisPluginError.self) {
            try await StubRedisChannel([.error("NOAUTH Authentication required.")]).probeHealth()
        }
    }
}
