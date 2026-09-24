import Foundation

/// Statement boundaries for the dialects whose only `;`-holding construct is a routine body written `BEGIN ... END`.
///
/// A `BEGIN` opens a body only inside a statement that defines a routine, for the safety reason recorded on
/// ``SqlBlockStructure/opensRoutineDefinition(_:)``. The `;` belongs to the statement only after a T-SQL `MERGE`, which
/// ``SQLLexicalGrammar/terminatedMergeStatements`` asks for: these engines accept every other statement without it.
public struct SQLRoutineBodyTracker: SQLStatementBoundaryTracking {
    private var sawStatementKeyword = false
    private var definesRoutine = false
    private var depth = 0
    private var pendingBegin = false
    private var pendingEnd = false
    private var merge: SQLMergeStatementTracker?

    public init(grammar: SQLLexicalGrammar) {
        self.init(merge: grammar.contains(.terminatedMergeStatements) ? SQLMergeStatementTracker() : nil)
    }

    private init(merge: SQLMergeStatementTracker?) {
        self.merge = merge
    }

    public var needsWords: Bool {
        !sawStatementKeyword || definesRoutine || merge?.needsWords == true
    }

    public var terminator: SQLStatementTerminator {
        merge?.endsInMerge == true ? .partOfStatement : .separator
    }

    public var acceptsBindParameters: Bool {
        true
    }

    public mutating func observeWord(_ word: String) {
        merge?.observeWord(word)
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
        merge?.observeSymbol(symbol)
        settlePendingBeforeNonWord()
    }

    public mutating func observeOpaqueToken() {
        merge?.observeOpaqueToken()
        settlePendingBeforeNonWord()
    }

    public mutating func observeSemicolon() -> Bool {
        pendingBegin = false
        if pendingEnd {
            pendingEnd = false
            closeBlock()
        }
        let endsStatement = depth == 0
        merge?.observeSemicolon(endsStatement: endsStatement)
        return endsStatement
    }

    public mutating func reset() {
        self = SQLRoutineBodyTracker(merge: merge.map { _ in SQLMergeStatementTracker() })
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
