import Foundation
import TableProDatabase
import TableProModels

// One connection's session lifecycle. Each async step carries the attempt it started under and lands only while the
// state still holds that attempt, so a dial or a load that returns after Cancel, or after a newer attempt, changes
// nothing.
enum ConnectionSessionState {
    case notConnected
    // `provisional` is the session an open reattached or dialed, held while the lists load.
    case connecting(ConnectionAttempt, provisional: ConnectionSession?)
    case connected(ConnectionSession)
    // A session check pinging the session, before it knows whether to redial.
    case checking(ConnectionAttempt, over: Resting)
    // A redial, or a PostgreSQL database switch, which leaves no session until the new one lands.
    case reconnecting(ConnectionAttempt, over: Resting)
    case failed(AppError)
    case lost(AppError)

    enum Resting {
        case connected(ConnectionSession)
        case lost(AppError)

        var phase: ConnectionCoordinator.ConnectionPhase {
            switch self {
            case .connected: return .connected
            case .lost(let error): return .lost(error)
            }
        }

        var settled: ConnectionSessionState {
            switch self {
            case .connected(let session): return .connected(session)
            case .lost(let error): return .lost(error)
            }
        }
    }

    enum Event {
        case open(ConnectionAttempt)
        case check(ConnectionAttempt)
        case dial(ConnectionAttempt)
        case switchDatabase(ConnectionAttempt)
        // A database switch inside an open drops the session the open had.
        case teardown(ConnectionAttempt)
        // With no attempt: a session another window moved or replaced, or a USE moved, taken in place.
        case adopt(ConnectionSession, by: ConnectionAttempt?)
        case settle(ConnectionAttempt)
        case opened(ConnectionAttempt)
        case fail(AppError, ConnectionAttempt)
        case lose(AppError, ConnectionAttempt)
        // The last window waiting left: an open goes back to the loss or failure it started from, so a window that
        // still shows it keeps its Reconnect, and a check or a switch goes back to the session it had.
        case abandon(ConnectionAttempt)
        // The record changed how it dials, so nothing of the old session is kept.
        case cancel
    }

    // Nil when the state refuses the event: a step of an attempt it no longer holds, or one it cannot take.
    func applying(_ event: Event) -> ConnectionSessionState? {
        switch event {
        case .open(let attempt):
            if isOpening { return nil }
            return .connecting(attempt, provisional: nil)
        case .check(let attempt):
            // A failed redial left nothing to ping, so a check over a loss dials again.
            guard let resting else { return nil }
            return .checking(attempt, over: resting)
        case .dial(let attempt):
            guard case .checking(let current, let over) = self, current === attempt else { return nil }
            return .reconnecting(attempt, over: over)
        case .switchDatabase(let attempt):
            // A check in flight finishes first, or its lost-transaction notice would never be given.
            guard let resting else { return nil }
            return .reconnecting(attempt, over: resting)
        case .teardown(let attempt):
            guard case .connecting(let current, _) = self, current === attempt else { return nil }
            return .connecting(attempt, provisional: nil)
        case .adopt(let session, let lander):
            guard let lander else { return replacingSession(with: session) }
            guard self.attempt === lander else { return nil }
            if isOpening { return .connecting(lander, provisional: session) }
            return .connected(session)
        case .settle(let attempt):
            guard self.attempt === attempt else { return nil }
            switch self {
            case .checking(_, let over), .reconnecting(_, let over): return over.settled
            case .notConnected, .connecting, .connected, .failed, .lost: return nil
            }
        case .opened(let attempt):
            guard case .connecting(let current, let provisional?) = self, current === attempt else { return nil }
            return .connected(provisional)
        case .fail(let error, let attempt):
            guard case .connecting(let current, _) = self, current === attempt else { return nil }
            return .failed(error)
        case .lose(let error, let attempt):
            guard self.attempt === attempt else { return nil }
            if case .checking = self { return nil }
            return .lost(error)
        case .abandon(let attempt):
            guard self.attempt === attempt else { return nil }
            return atRest
        case .cancel:
            return .notConnected
        }
    }

    // What a window shows once nothing is in flight: the loss or failure an open started from, or the session a
    // check or a switch started over.
    var atRest: ConnectionSessionState {
        switch self {
        case .connecting(let attempt, _):
            switch attempt.origin {
            case .failed(let error)?: return .failed(error)
            case .lost(let error)?: return .lost(error)
            case nil: return .notConnected
            }
        case .checking(_, let over), .reconnecting(_, let over):
            return over.settled
        case .notConnected, .connected, .failed, .lost:
            return self
        }
    }

    // What an open started here goes back to when every window waiting on it leaves.
    var openOrigin: ConnectionAttempt.Origin? {
        switch self {
        case .failed(let error): return .failed(error)
        case .lost(let error): return .lost(error)
        case .notConnected, .connecting, .connected, .checking, .reconnecting: return nil
        }
    }

    var attempt: ConnectionAttempt? {
        switch self {
        case .connecting(let attempt, _), .checking(let attempt, _), .reconnecting(let attempt, _): return attempt
        case .notConnected, .connected, .failed, .lost: return nil
        }
    }

    // The running session check, which a later trigger joins.
    var check: ConnectionAttempt? {
        guard let attempt, attempt.purpose == .redial else { return nil }
        return attempt
    }

    var session: ConnectionSession? {
        switch self {
        case .connecting(_, let provisional):
            return provisional
        case .connected(let session), .checking(_, .connected(let session)):
            return session
        case .reconnecting(let attempt, .connected(let session)):
            return attempt.purpose == .switchDatabase ? nil : session
        case .notConnected, .checking(_, .lost), .reconnecting(_, .lost), .failed, .lost:
            return nil
        }
    }

    var phase: ConnectionCoordinator.ConnectionPhase {
        switch self {
        case .notConnected: return .notConnected
        case .connecting: return .connecting
        case .connected: return .connected
        case .checking(_, let over), .reconnecting(_, let over): return over.phase
        case .failed(let error): return .failed(error)
        case .lost(let error): return .lost(error)
        }
    }

    // A database switch names its target instead.
    var isReconnecting: Bool {
        guard case .reconnecting(let attempt, _) = self else { return false }
        return attempt.purpose == .redial
    }

    var isOpening: Bool {
        if case .connecting = self { return true }
        return false
    }

    private var resting: Resting? {
        switch self {
        case .connected(let session): return .connected(session)
        case .lost(let error): return .lost(error)
        case .notConnected, .connecting, .checking, .reconnecting, .failed: return nil
        }
    }

    private func replacingSession(with session: ConnectionSession) -> ConnectionSessionState? {
        switch self {
        case .connecting(let attempt, _):
            return .connecting(attempt, provisional: session)
        case .connected:
            return .connected(session)
        case .checking(let attempt, .connected):
            return .checking(attempt, over: .connected(session))
        case .reconnecting(let attempt, .connected) where attempt.purpose == .redial:
            return .reconnecting(attempt, over: .connected(session))
        case .notConnected, .checking(_, .lost), .reconnecting, .failed, .lost:
            return nil
        }
    }
}

// One open, session check or PostgreSQL database switch. Its identity is what a late step is checked against.
final class ConnectionAttempt {
    nonisolated enum Purpose {
        case open
        case redial
        case switchDatabase
    }

    enum Origin {
        case failed(AppError)
        case lost(AppError)
    }

    let purpose: Purpose
    // For an open: the loss or failure it started from.
    let origin: Origin?
    // The windows that asked for it or wait on it, first asker first; the last one to leave abandons it.
    private(set) var consumers: [ObjectIdentifier] = []
    // A statement failed while this redial ran, so it may have ended the transaction itself.
    var ambiguous = false
    var task: Task<Bool, Never>?

    init(_ purpose: Purpose, origin: Origin? = nil) {
        self.purpose = purpose
        self.origin = origin
    }

    func join(_ consumer: AnyObject) {
        let id = ObjectIdentifier(consumer)
        guard !consumers.contains(id) else { return }
        consumers.append(id)
    }

    // True when that consumer was the last one.
    func leave(_ consumer: AnyObject) -> Bool {
        guard let index = consumers.firstIndex(of: ObjectIdentifier(consumer)) else { return false }
        consumers.remove(at: index)
        return consumers.isEmpty
    }
}

// What a window's lists show and where they were read.
nonisolated struct ConnectionCatalog: Equatable {
    nonisolated struct Placement: Hashable {
        var database: String
        var schema: String
    }

    var placement = Placement(database: "", schema: "public")
    var databases: [String] = []
    var schemas: [String] = []
    var tables: [TableInfo] = []
    // A table read was refused; the lists reload in full once nothing holds the session.
    var tablesRefused = false
}
