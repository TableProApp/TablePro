import Foundation

/// Statement boundaries for the dialects whose only `;`-holding construct is a routine body written `BEGIN ... END`.
///
/// A `BEGIN` opens a body only inside a statement that defines a routine, for the safety reason recorded on
/// ``SqlBlockStructure/opensRoutineDefinition(_:)``. The `;` belongs to the statement only after a T-SQL `MERGE`, which
/// ``SQLLexicalGrammar/terminatedMergeStatements`` asks for: these engines accept every other statement without it.
///
/// `BEGIN`, `CASE` and `END` count only where a keyword can stand: an engine that does not reserve them takes them as
/// names, and a block a name opened would never close. A text left inside one is refused by the external gate.
public struct SQLRoutineBodyTracker: SQLStatementBoundaryTracking {
    private enum Header {
        case opener
        /// After `CREATE`, `ALTER` or `REPLACE`. `accountWords` is what is left of an unquoted `DEFINER = user@host`.
        case kind(accountWords: Int)
        /// After the kind, or after `DECLARE`: the next word names what is defined.
        case name
        case read
    }

    private static let dot = UInt16(UnicodeScalar(".").value)
    private static let colon = UInt16(UnicodeScalar(":").value)

    /// The words a statement inside a body can follow without a `;`, as in `IF x THEN BEGIN ... END; END IF`.
    private static let statementIntroducers: Set<String> = ["THEN", "ELSE", "DO", "LOOP", "REPEAT"]

    private let grammar: SQLLexicalGrammar
    private var header = Header.opener
    private var definesRoutine = false
    private var openedBlockBody = false
    private var depth = 0

    /// The open `CASE`s that have held no `;`, which only a `CASE` statement can. The next `END` closes one of them,
    /// whatever word follows it.
    private var openCaseExpressions = 0
    private var parenDepth = 0
    private var pendingBegin = false
    private var pendingEnd = false
    private var followsName = false
    private var followsDot = false
    private var startsBodyStatement = false

    // Where a statement inside a body can start, which is the only place a nested `BEGIN` opens a block: `begin` is
    // a name anywhere else on an engine that does not reserve it. T-SQL reserves it and writes `IF @x = 1 BEGIN`.
    private var atStatementPosition = false
    private var labelMayFollow = false
    private var inDeclaration = false
    private var inHandlerDeclaration = false
    private var merge: SQLMergeStatementTracker?

    public init(grammar: SQLLexicalGrammar) {
        self.grammar = grammar
        self.merge = grammar.contains(.terminatedMergeStatements) ? SQLMergeStatementTracker() : nil
    }

    public var needsWords: Bool {
        if case .read = header {
            return definesRoutine || merge?.needsWords == true
        }
        return true
    }

    public var terminator: SQLStatementTerminator {
        merge?.endsInMerge == true ? .partOfStatement : .separator
    }

    public var acceptsBindParameters: Bool {
        !(openedBlockBody && grammar.contains(.sqlScriptBlocks))
    }

    // An `END` still waiting for the word after it closes a block when the text ends.
    public var holdsOpenBlock: Bool {
        depth > (pendingEnd ? 1 : 0)
    }

    public mutating func observeWord(_ word: String) {
        merge?.observeWord(word)
        let isMember = followsDot
        followsName = true
        followsDot = false
        if settlePending(before: word) {
            atStatementPosition = false
            labelMayFollow = false
            return
        }
        let startsStatement = startsBodyStatement
        startsBodyStatement = false
        let statementPosition = atStatementPosition
        observeStatementPosition(after: word, wasAtStatementPosition: statementPosition)
        guard !isMember, readHeader(word), definesRoutine, parenDepth == 0 else { return }
        switch word {
        case "BEGIN" where opensNestedBlock(atStatementPosition: statementPosition):
            pendingBegin = true
        case "CASE" where !grammar.hasSingleBodyForm:
            depth += 1
            openCaseExpressions += 1
        case "END" where !grammar.hasSingleBodyForm || startsStatement:
            pendingEnd = true
        default:
            break
        }
    }

    public mutating func observeSymbol(_ symbol: UInt16) {
        merge?.observeSymbol(symbol)
        let opensBlock = symbol == SqlLexer.openParen && !grammar.contains(.atomicRoutineBodies)
        settlePendingBeforeNonWord(opensBlock: opensBlock)
        followsDot = followsName && symbol == Self.dot
        followsName = false
        atStatementPosition = symbol == Self.colon && labelMayFollow
        labelMayFollow = false
        switch symbol {
        case SqlLexer.openParen:
            parenDepth += 1
            endName()
        case SqlLexer.closeParen:
            parenDepth = max(0, parenDepth - 1)
        default:
            break
        }
    }

    public mutating func observeOpaqueToken() {
        merge?.observeOpaqueToken()
        settlePendingBeforeNonWord(opensBlock: !grammar.contains(.atomicRoutineBodies))
        followsName = true
        followsDot = false
        atStatementPosition = false
        labelMayFollow = false
        endName()
    }

    public mutating func observeGap() {
        merge?.observeGap()
    }

    public mutating func observeSemicolon() -> Bool {
        pendingBegin = false
        if pendingEnd {
            pendingEnd = false
            closeBlock()
        }
        openCaseExpressions = 0
        parenDepth = 0
        followsName = false
        followsDot = false
        let endsStatement = depth == 0
        startsBodyStatement = !endsStatement
        atStatementPosition = !endsStatement
        labelMayFollow = false
        inDeclaration = false
        inHandlerDeclaration = false
        merge?.observeSemicolon(endsStatement: endsStatement)
        return endsStatement
    }

    public mutating func reset() {
        self = SQLRoutineBodyTracker(grammar: grammar)
    }

    // MARK: - Private

    /// Returns whether `word` comes after the header, where it can be a block keyword.
    private mutating func readHeader(_ word: String) -> Bool {
        switch header {
        case .opener:
            if SqlBlockStructure.opensRoutineDefinition(word) {
                header = .kind(accountWords: 0)
            } else if SqlBlockStructure.opensDeclarations(word, grammar: grammar) {
                definesRoutine = true
                header = .name
            } else {
                definesRoutine = SqlBlockStructure.opensAnonymousBlock(word, grammar: grammar)
                header = .read
            }
            return false
        case .kind(let accountWords):
            if SqlBlockStructure.isRoutineKind(word, grammar: grammar) {
                definesRoutine = true
                header = .name
            } else if word == "DEFINER" {
                header = .kind(accountWords: 2)
            } else if !SqlBlockStructure.precedesRoutineKind(word) {
                header = accountWords > 0 ? .kind(accountWords: accountWords - 1) : .read
            }
            return false
        case .name:
            // PostgreSQL's `EVENT TRIGGER` is a kind of two words, so a second kind still precedes the name.
            if !SqlBlockStructure.precedesRoutineName(word), !SqlBlockStructure.isRoutineKind(word, grammar: grammar) {
                header = .read
            }
            return false
        case .read:
            return true
        }
    }

    // A label, `lbl:`, is a word at a statement's start followed by `:`. A handler's body follows its condition.
    private mutating func observeStatementPosition(after word: String, wasAtStatementPosition: Bool) {
        atStatementPosition = depth > 0 && Self.statementIntroducers.contains(word)
        labelMayFollow = wasAtStatementPosition
        if wasAtStatementPosition, word == "DECLARE" {
            inDeclaration = true
        }
        if inDeclaration, word == "HANDLER" {
            inHandlerDeclaration = true
        }
    }

    private func opensNestedBlock(atStatementPosition: Bool) -> Bool {
        guard depth > 0, !grammar.hasSingleBodyForm, !grammar.contains(.unterminatedStatements) else { return true }
        return atStatementPosition || inHandlerDeclaration
    }

    private mutating func endName() {
        if case .name = header {
            header = .read
        }
    }

    /// Returns whether `word` was consumed by the keyword before it, as `IF` is in `END IF`.
    private mutating func settlePending(before word: String) -> Bool {
        if pendingBegin {
            pendingBegin = false
            if grammar.contains(.atomicRoutineBodies) {
                guard word == "ATOMIC" else { return false }
                openBlockBody()
                return true
            }
            if !SqlBlockStructure.beginStartsTransaction(followedBy: word) {
                openBlockBody()
            }
        }
        guard pendingEnd else { return false }
        pendingEnd = false
        guard !grammar.hasSingleBodyForm else {
            closeBlock()
            return false
        }
        switch SqlBlockStructure.endingFollowedBy(word, closesCaseExpression: openCaseExpressions > 0) {
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

    // A `begin` before an operator other than `(` is a name or an operand; before `(`, a literal or a parameter it
    // opens a body, whose first statement may be a parenthesized query. An `END` before anything but a word closes one.
    private mutating func settlePendingBeforeNonWord(opensBlock: Bool) {
        if pendingBegin {
            pendingBegin = false
            if opensBlock {
                openBlockBody()
            }
        }
        if pendingEnd {
            pendingEnd = false
            closeBlock()
        }
        startsBodyStatement = false
    }

    // A trigger body holds no other; `BEGIN ATOMIC` is never a name, so a routine defined inside one nests.
    private mutating func openBlockBody() {
        guard !grammar.contains(.triggerBodies) || depth == 0 else { return }
        depth += 1
        openedBlockBody = true
        startsBodyStatement = true
        atStatementPosition = true
    }

    private mutating func closeBlock() {
        depth = max(0, depth - 1)
        openCaseExpressions = max(0, openCaseExpressions - 1)
    }
}
