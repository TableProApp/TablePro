import Foundation

/// Statement boundaries for the dialects whose only `;`-holding construct is a routine body written `BEGIN ... END`.
///
/// Outside T-SQL a `BEGIN` opens a body only inside a statement that defines a routine, for the safety reason recorded on
/// ``SqlBlockStructure/opensRoutineDefinition(_:)``. The `;` belongs to the statement only after a T-SQL `MERGE`, which
/// ``SQLLexicalGrammar/terminatedMergeStatements`` asks for: these engines accept every other statement without it.
///
/// `BEGIN`, `CASE` and `END` count only where a keyword can stand: an engine that does not reserve them takes them as
/// names, and a block a name opened would never close. T-SQL reserves all three, so there a block also opens outside
/// a routine, as in `IF @x = 1 BEGIN ... END` and `BEGIN TRY ... END TRY BEGIN CATCH ... END CATCH`. A text left
/// inside one is refused by the external gate. T-SQL also lets a `;` end an `IF`'s body before its `ELSE`, as in
/// `IF @x = 1 SELECT 1; ELSE SELECT 2;`, so that `;` ends the statement only once the next token is not the `ELSE`.
///
/// A `;` inside parentheses ends the statement, so a stray `(` cannot swallow what follows it, except in a PostgreSQL
/// rule's action list, `DO ALSO (INSERT ...; INSERT ...)`, which holds its commands together.
public struct SQLRoutineBodyTracker: SQLStatementBoundaryTracking {
    // A PostgreSQL `CREATE RULE`: its header, the `DO [ALSO | INSTEAD]` before the action list, and the list itself.
    private enum RuleAction: Equatable {
        case none
        case header
        case afterDo
        case list(depth: Int)
    }

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
    private let readsBlocksEverywhere: Bool
    // T-SQL outside a routine: where a block's `BEGIN` can stand, as the statement's first word, after `IF`, `WHILE`
    // or `ELSE`, or after a block the statement already opened. Anywhere else `begin` is in a name's place.
    private var followsControlFlow = false
    // The statement's own `IF`s still waiting for an `ELSE`, which may follow the `;` that ends the `IF`'s body.
    private var conditionalsAwaitingElse = 0
    private var endedBeforeElse = false
    private var pendingBeginMayOpen = false
    private var header = Header.opener
    private var definesRoutine = false
    private var openedBlockBody = false
    private var depth = 0

    /// The open `CASE`s that have held no `;`, which only a `CASE` statement can. The next `END` closes one of them,
    /// whatever word follows it.
    private var openCaseExpressions = 0
    private var parenDepth = 0
    private var ruleAction = RuleAction.none
    private var ruleActionHeldSemicolon = false
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
        self.readsBlocksEverywhere = grammar.contains(.unterminatedStatements)
        self.merge = grammar.contains(.terminatedMergeStatements) ? SQLMergeStatementTracker() : nil
    }

    public var needsWords: Bool {
        // Inside parentheses no word opens or closes a block, and a `MERGE` there needs no `;`.
        if readsBlocksEverywhere { return parenDepth == 0 }
        if case .read = header {
            return definesRoutine || ruleAction == .header || ruleAction == .afterDo || merge?.needsWords == true
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
        depth > (pendingEnd ? 1 : 0) || ruleActionHeldSemicolon
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
        guard !isMember else { return }
        var isFirstWord = false
        if case .opener = header {
            isFirstWord = true
        }
        let pastHeader = readHeader(word)
        if pastHeader, parenDepth == 0 {
            observeRuleWord(word)
        }
        guard parenDepth == 0, readsBlocksEverywhere || (pastHeader && definesRoutine) else { return }
        switch word {
        case "BEGIN" where readsBlocksEverywhere:
            pendingBegin = true
            pendingBeginMayOpen = opensNestedBlock(atStatementPosition: statementPosition, isFirstWord: isFirstWord)
        case "BEGIN" where opensNestedBlock(atStatementPosition: statementPosition, isFirstWord: isFirstWord):
            pendingBegin = true
            pendingBeginMayOpen = true
        case "IF" where readsBlocksEverywhere:
            followsControlFlow = true
            if depth == 0 {
                conditionalsAwaitingElse += 1
            }
        case "WHILE" where readsBlocksEverywhere:
            followsControlFlow = true
        case "ELSE" where readsBlocksEverywhere && openCaseExpressions == 0:
            followsControlFlow = true
            if depth == 0 {
                conditionalsAwaitingElse = max(0, conditionalsAwaitingElse - 1)
            }
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
        if ruleAction == .afterDo, symbol != SqlLexer.openParen {
            ruleAction = .none
        }
        let opensBlock = symbol == SqlLexer.openParen && !grammar.contains(.atomicRoutineBodies)
        settlePendingBeforeNonWord(opensBlock: opensBlock)
        followsDot = followsName && symbol == Self.dot
        followsName = false
        atStatementPosition = symbol == Self.colon && labelMayFollow
        labelMayFollow = false
        switch symbol {
        case SqlLexer.openParen:
            parenDepth += 1
            if ruleAction == .afterDo {
                ruleAction = .list(depth: parenDepth)
            }
            endName()
        case SqlLexer.closeParen:
            parenDepth = max(0, parenDepth - 1)
            if case .list(let listDepth) = ruleAction, parenDepth < listDepth {
                ruleAction = .none
                ruleActionHeldSemicolon = false
            }
        default:
            break
        }
    }

    public mutating func observeOpaqueToken() {
        merge?.observeOpaqueToken()
        if ruleAction == .afterDo {
            ruleAction = .none
        }
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
        if readsBlocksEverywhere {
            // A T-SQL `CASE` is only an expression, which no `;` can stand inside, so one still open was never closed.
            depth = max(0, depth - openCaseExpressions)
        }
        openCaseExpressions = 0
        followsName = false
        followsDot = false
        let heldByRuleAction: Bool
        if case .list(let listDepth) = ruleAction {
            heldByRuleAction = depth == 0 && parenDepth >= listDepth
        } else {
            heldByRuleAction = false
        }
        if heldByRuleAction {
            ruleActionHeldSemicolon = true
        } else {
            parenDepth = 0
        }
        let endsStatement = depth == 0 && !heldByRuleAction
        startsBodyStatement = depth > 0
        atStatementPosition = depth > 0
        labelMayFollow = false
        inDeclaration = false
        inHandlerDeclaration = false
        merge?.observeSemicolon(endsStatement: endsStatement)
        endedBeforeElse = endsStatement && readsBlocksEverywhere && conditionalsAwaitingElse > 0
        return endsStatement
    }

    public var awaitsContinuation: Bool {
        endedBeforeElse
    }

    // T-SQL writes `IF c SELECT 1; ELSE SELECT 2;`, so the `;` ended the `IF`'s body rather than the `IF`.
    public mutating func continuesStatement(with word: String?) -> Bool {
        guard endedBeforeElse else { return false }
        endedBeforeElse = false
        guard word == "ELSE" else { return false }
        merge?.observeSemicolon(endsStatement: false)
        return true
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
            if word == "RULE", grammar.contains(.atomicRoutineBodies) {
                ruleAction = .header
            }
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

    private func opensNestedBlock(atStatementPosition: Bool, isFirstWord: Bool) -> Bool {
        if readsBlocksEverywhere {
            return depth > 0 || definesRoutine || isFirstWord || followsControlFlow || openedBlockBody
        }
        guard depth > 0, !grammar.hasSingleBodyForm else { return true }
        return atStatementPosition || inHandlerDeclaration
    }

    private mutating func observeRuleWord(_ word: String) {
        switch ruleAction {
        case .header where word == "DO":
            ruleAction = .afterDo
        case .afterDo where word == "ALSO" || word == "INSTEAD":
            break
        case .afterDo:
            ruleAction = .none
        default:
            break
        }
    }

    // `BEGIN TRY` and `BEGIN CATCH` are blocks wherever they stand, and nothing else follows a name that way.
    private func beginOpensBlock(followedBy word: String) -> Bool {
        if readsBlocksEverywhere, word == "TRY" || word == "CATCH" { return true }
        return pendingBeginMayOpen && !SqlBlockStructure.beginStartsStatement(followedBy: word, grammar: grammar)
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
            if beginOpensBlock(followedBy: word) {
                openBlockBody()
            }
        }
        guard pendingEnd else { return false }
        pendingEnd = false
        guard !grammar.hasSingleBodyForm else {
            closeBlock()
            return false
        }
        switch SqlBlockStructure.endingFollowedBy(word, closesCaseExpression: openCaseExpressions > 0, grammar: grammar) {
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
            // A T-SQL `begin(` outside a routine is a name, as in `CREATE TABLE begin(a int)`.
            let opensAfterName = !readsBlocksEverywhere || definesRoutine || depth > 0
            if opensBlock, pendingBeginMayOpen, opensAfterName {
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
