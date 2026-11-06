// A reconnect never clears this: a stale true costs one round trip, a stale false loses a statement's DBMS_OUTPUT lines.
internal struct OracleServerOutputPending: Sendable, Equatable {
    private(set) var needsRead = false

    mutating func noteStatement() {
        needsRead = true
    }

    mutating func noteRead() {
        needsRead = false
    }
}
