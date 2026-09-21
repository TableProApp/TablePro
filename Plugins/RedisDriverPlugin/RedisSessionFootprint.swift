//
//  RedisSessionFootprint.swift
//  RedisDriverPlugin
//
//  The state a user's MULTI or WATCH leaves on the server session, which every command on the
//  connection shares because Redis never pools. Measured on Redis 8.10.1:
//
//  - Inside a block only EXEC, DISCARD, MULTI, WATCH, QUIT and RESET run; every other command
//    answers `+QUEUED`, or an error that marks the block so EXEC answers EXECABORT.
//  - A nested MULTI, a WATCH inside a block and a refused MULTI or DISCARD leave the block as it was.
//  - EXEC ends the block and every WATCH whatever it answers; with no block open it is refused and
//    the WATCH stays. RESET ends both and moves the session to database 0.
//  - A server drops a client's block and its watched keys when the connection closes.
//
//  So the app's own reads have to stay out of an open block, and a reconnect over one has to say
//  the block is gone rather than replay into a session that never had it.
//

import Foundation
import TableProPluginKit

enum RedisCommandScope: Equatable, Sendable {
    /// A command the user typed, which belongs in their block when one is open.
    case session
    /// A read the app makes on its own, which must never join the user's block.
    case outsideBlock
    /// The app's own transaction, which needs a session holding no block and no watched keys.
    case cleanSession
}

enum RedisHeldState: Equatable, Sendable {
    case openBlock
    case watchedKeys
}

struct RedisSessionFootprint: Equatable, Sendable {
    private(set) var hasOpenBlock = false
    private(set) var isWatching = false
    private(set) var pendingLoss: RedisHeldState?
    private var queuedDatabase = RedisQueuedDatabase()

    var pendingDatabase: Int? { queuedDatabase.pending }

    var heldState: RedisHeldState? {
        if hasOpenBlock { return .openBlock }
        return isWatching ? .watchedKeys : nil
    }

    func heldBack(_ scope: RedisCommandScope) -> RedisHeldState? {
        switch scope {
        case .session:
            return nil
        case .outsideBlock:
            return hasOpenBlock ? .openBlock : nil
        case .cleanSession:
            return heldState
        }
    }

    /// A loss is reported once, to the next command the user sends.
    mutating func takePendingLoss() -> RedisHeldState? {
        defer { pendingLoss = nil }
        return pendingLoss
    }

    mutating func adoptLoss(_ held: RedisHeldState?) {
        guard let held, pendingLoss == nil else { return }
        pendingLoss = held
    }

    mutating func queueDatabase(_ index: Int) {
        queuedDatabase.queue(index)
    }

    /// The session the state lived on is gone, so whatever it held is latched as lost and the
    /// footprint starts again from a clean session.
    mutating func sessionEnded() {
        adoptLoss(heldState)
        hasOpenBlock = false
        isWatching = false
        queuedDatabase.clear()
    }

    /// Returns the database the session moved to when the reply moved it.
    mutating func observe(command: String?, reply: RedisReply) -> Int? {
        let name = command?.uppercased() ?? ""
        let movedTo = queuedDatabase.resolve(command: name, reply: reply)
        if reply.isQueued {
            hasOpenBlock = true
            return movedTo
        }
        switch name {
        case "MULTI":
            if !reply.isError { hasOpenBlock = true }
        case "EXEC":
            guard hasOpenBlock else { return movedTo }
            endTransaction()
        case "DISCARD":
            if !reply.isError { endTransaction() }
        case "RESET":
            guard !reply.isError else { return movedTo }
            endTransaction()
            return 0
        case "WATCH":
            if !reply.isError { isWatching = true }
        case "UNWATCH":
            if !reply.isError { isWatching = false }
        default:
            if !reply.isError { hasOpenBlock = false }
        }
        return movedTo
    }

    private mutating func endTransaction() {
        hasOpenBlock = false
        isWatching = false
    }
}

/// Which numbered database the session is on, and which one it belongs on.
///
/// A read the app makes for one row visits that row's database and returns, and every other
/// command runs where the session belongs. Each command checks right before it is sent, because
/// neither the move nor the return is atomic with the commands around it: a cancelled stream can
/// release the driver before its return reaches the server, and the health monitor's PING is not
/// held back by the session gate, so it can arrive in the middle of a visit.
struct RedisSessionDatabase: Equatable, Sendable {
    private(set) var current: Int
    private(set) var home: Int

    init(_ index: Int) {
        current = index
        home = index
    }

    /// A SELECT the user typed, or a move the app made on their behalf.
    mutating func selected(_ index: Int) {
        current = index
        home = index
    }

    mutating func visited(_ index: Int) {
        current = index
    }

    /// The database a command has to move to before it runs, or nil when the session is already
    /// there: the one being visited for a command that is part of a visit, home for any other.
    func databaseToMoveTo(visiting: Int?) -> Int? {
        let target = visiting ?? home
        return current == target ? nil : target
    }
}

/// The database a read the app makes for one row is visiting, for the length of that read.
enum RedisDatabaseVisit {
    @TaskLocal static var database: Int?
}

/// A command the app did not send because the user's session holds state it would disturb.
struct RedisHeldBackCommand: Error, Equatable {
    let command: String
    let held: RedisHeldState
}

extension RedisHeldBackCommand: PluginDriverError {
    var pluginErrorMessage: String {
        switch held {
        case .openBlock:
            return String(format: String(localized: "%@ was not sent because a MULTI block is open on this connection."), commandName)
        case .watchedKeys:
            return String(format: String(localized: "%@ was not sent because this connection is watching keys."), commandName)
        }
    }

    var pluginErrorDetail: String? {
        switch held {
        case .openBlock:
            return String(localized: "Run EXEC to apply the block, or DISCARD to drop it.")
        case .watchedKeys:
            return String(localized: "Run EXEC, DISCARD or UNWATCH first.")
        }
    }

    private var commandName: String {
        command.isEmpty ? String(localized: "The command") : command.uppercased()
    }
}

/// The connection dropped while the session held a block or watched keys, which the server
/// discards with the connection.
struct RedisSessionStateLost: Error, Equatable {
    let held: RedisHeldState
    /// EXEC reached the server before the connection dropped, so the block may have run.
    let outcomeUnknown: Bool
}

extension RedisSessionStateLost: PluginDriverError {
    var pluginErrorMessage: String {
        switch held {
        case .openBlock where outcomeUnknown:
            return String(localized: "The connection to Redis dropped after EXEC was sent, so whether the block ran is unknown.")
        case .openBlock:
            return String(localized: "The connection to Redis dropped, so the open MULTI block was lost and nothing in it ran.")
        case .watchedKeys:
            return String(localized: "The connection to Redis dropped, so the keys this session was watching are no longer watched.")
        }
    }

    var pluginErrorDetail: String? {
        switch held {
        case .openBlock where outcomeUnknown:
            return String(localized: "Check the keys the block writes before running it again.")
        case .openBlock:
            return String(localized: "Start the block again with MULTI.")
        case .watchedKeys:
            return String(localized: "Run WATCH again before starting the block.")
        }
    }
}
