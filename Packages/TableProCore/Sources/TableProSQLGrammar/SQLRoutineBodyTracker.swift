import Foundation

/// Statement boundaries for the dialects whose only `;`-holding construct is a routine body written `BEGIN ... END`.
///
/// A `BEGIN` opens a body only inside a statement that defines a routine, for the safety reason recorded on
/// ``SqlBlockStructure/opensRoutineDefinition(_:)``. The `;` never belongs to the statement: every one of these
/// engines accepts a statement without it.
public struct SQLRoutineBodyTracker: SQLStatementBoundaryTracking {
    private var sawStatementKeyword = false
    private var definesRoutine = false
    private var depth = 0
    private var pendingBegin = false
    private var pendingEnd = false

    public init() {}

    public var needsWords: Bool {
        !sawStatementKeyword || definesRoutine
    }

    public var terminator: SQLStatementTerminator {
        .separator
    }

    public var acceptsBindParameters: Bool {
        true
    }

    public mutating func observeWord(_ word: String) {
        if settlePending(before: word) { return }
        if !sawStatementKeyword {
            sawStatementKeyword = true
            definesRoutine = SqlBlockStructure.opensRoutineDefinition(word)
        }
        guard definesRoutine else { return }
        switch word {
        case "BEGIN":
            pendingBegin = true
        case "CASE":
            depth += 1
        case "END":
            pendingEnd = true
        default:
            break
        }
    }

    public mutating func observeSymbol(_ symbol: UInt16) {
        settlePendingBeforeNonWord()
    }

    public mutating func observeOpaqueToken() {
        settlePendingBeforeNonWord()
    }

    public mutating func observeSemicolon() -> Bool {
        pendingBegin = false
        if pendingEnd {
            pendingEnd = false
            closeBlock()
        }
        return depth == 0
    }

    public mutating func reset() {
        self = SQLRoutineBodyTracker()
    }

    // MARK: - Private

    /// Returns whether `word` was consumed by the keyword before it, as `IF` is in `END IF`.
    private mutating func settlePending(before word: String) -> Bool {
        if pendingBegin {
            pendingBegin = false
            if !SqlBlockStructure.beginStartsTransaction(followedBy: word) {
                depth += 1
            }
        }
        guard pendingEnd else { return false }
        pendingEnd = false
        switch SqlBlockStructure.endingFollowedBy(word) {
        case .closesControlFlow:
            return true
        case .closesCaseStatement:
            closeBlock()
            return true
        case .closesBlock:
            closeBlock()
            return false
        }
    }

    /// A `BEGIN` followed by anything but a word opens a block, and an `END` followed by anything but a word closes
    /// one, which is what the lookahead these rules replaced decided for the same input.
    private mutating func settlePendingBeforeNonWord() {
        if pendingBegin {
            pendingBegin = false
            depth += 1
        }
        if pendingEnd {
            pendingEnd = false
            closeBlock()
        }
    }

    private mutating func closeBlock() {
        depth = max(0, depth - 1)
    }
}
