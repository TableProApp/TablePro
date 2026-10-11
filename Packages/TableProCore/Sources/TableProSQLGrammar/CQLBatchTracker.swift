import Foundation

/// Statement boundaries for CQL, whose only construct that holds a `;` is a batch.
///
/// Cassandra and ScyllaDB run `BEGIN [UNLOGGED | COUNTER] BATCH ... APPLY BATCH` as one statement, and the `;` after
/// each statement inside it belongs to the batch: sent apart, the pieces fail as syntax errors. cqlsh keeps a batch
/// whole the same way. The batch ends at the first `;` after `APPLY BATCH`, or with the text. CQL has no
/// `BEGIN ... END` body, its function bodies are literals, and `CASE` is not one of its keywords, so the routine body
/// rules of ``SQLRoutineBodyTracker`` would only misread a column named `case` as a block that never closes.
public struct CQLBatchTracker: SQLStatementBoundaryTracking {
    private enum Phase {
        case start
        case afterOpener
        case afterKind
        case plainStatement
        case insideBatch
        case afterCloser
        case applied
    }

    private var phase = Phase.start

    public init() {}

    public var needsWords: Bool {
        phase != .plainStatement && phase != .applied
    }

    public var terminator: SQLStatementTerminator {
        .separator
    }

    public var acceptsBindParameters: Bool {
        true
    }

    public mutating func observeWord(_ word: String) {
        switch phase {
        case .start:
            phase = word == CQLBatch.opener ? .afterOpener : .plainStatement
        case .afterOpener where CQLBatch.kinds.contains(word):
            phase = .afterKind
        case .afterOpener, .afterKind:
            phase = word == CQLBatch.keyword ? .insideBatch : .plainStatement
        case .afterCloser where word == CQLBatch.keyword:
            phase = .applied
        case .insideBatch, .afterCloser:
            phase = word == CQLBatch.closer ? .afterCloser : .insideBatch
        case .plainStatement, .applied:
            break
        }
    }

    public mutating func observeSymbol(_ symbol: UInt16) {
        settleBeforeNonWord()
    }

    public mutating func observeOpaqueToken() {
        settleBeforeNonWord()
    }

    public mutating func observeGap() {}

    public mutating func observeSemicolon() -> Bool {
        switch phase {
        case .insideBatch, .afterCloser:
            phase = .insideBatch
            return false
        case .start, .afterOpener, .afterKind, .plainStatement, .applied:
            return true
        }
    }

    public mutating func reset() {
        self = CQLBatchTracker()
    }

    // MARK: - Private

    /// The batch keywords have to be consecutive words: `BEGIN` before a symbol or a literal opens no batch, and
    /// `APPLY` before one closes nothing.
    private mutating func settleBeforeNonWord() {
        switch phase {
        case .start, .afterOpener, .afterKind:
            phase = .plainStatement
        case .afterCloser:
            phase = .insideBatch
        case .plainStatement, .insideBatch, .applied:
            break
        }
    }
}
