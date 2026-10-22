import Foundation

// The sessions a killSessions is on its way for. A Stop sent again while one is queued would add a control client
// per resend, each waiting out the connect timeout when the server cannot be reached.
nonisolated struct MongoSessionKills: Sendable {
    private var pending: Set<String> = []

    mutating func begin(_ session: String) -> Bool {
        pending.insert(session).inserted
    }

    mutating func end(_ session: String) {
        pending.remove(session)
    }
}
