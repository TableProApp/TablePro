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
///
/// On MySQL a routine's body is one statement (``SQLLexicalGrammar/compoundStatementBodies``), so an `IF`, `WHILE`,
/// `LOOP` or `REPEAT` where a statement starts holds its `;`s up to its own `END IF` or kin, as `BEGIN ... END` does.
public struct SQLRoutineBodyTracker: SQLStatementBoundaryTracking {
    // A PostgreSQL `CREATE RULE`: its header, the `DO [ALSO | INSTEAD]` before the action list, and the list itself.
    private enum RuleAction: Equatable {
        case none
        case header
        case afterDo
        case list(depth: Int)
    }

    // How a routine's body began outside a block. A statement never holds a block. After a `RETURN` a block opens
    // only behind `AS` or `IS`, as the header `RETURN INT AS BEGIN` writes it. A control statement such as `IF` may
    // hold blocks, and statement words inside it begin nothing.
    private enum RoutineBody {
        case unknown
        case statement
        case returnValue
        case controlStatement
    }

    // A MySQL compound statement whose block is open, with the depth inside it, so `END IF` closes only an `IF`.
    private struct ControlStatement {
        let keyword: String
        let depth: Int
    }

    // A handler declaration, `DECLARE ... HANDLER FOR condition [, condition] statement`, read up to its statement's
    // first word, the one place in it where a statement starts.
    private enum HandlerPart {
        case none
        case header
        case condition
        case sqlState
        case notFound
        case afterCondition
        case statement
    }

    private enum NestedDefinition {
        case none
        case opener
        case routine
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
    private static let comma = UInt16(UnicodeScalar(",").value)
    private static let zero = UInt16(UnicodeScalar("0").value)
    private static let nine = UInt16(UnicodeScalar("9").value)

    /// The words a statement inside a body can follow without a `;`, as in `IF x THEN BEGIN ... END; END IF`.
    private static let statementIntroducers: Set<String> = ["THEN", "ELSE", "DO", "LOOP", "REPEAT"]

    /// The words that open a routine body written as one statement, as in MySQL's
    /// `CREATE PROCEDURE p() SELECT ... ORDER BY begin DESC`, where `begin` is a column.
    private static let singleStatementBodyOpeners: Set<String> = [
        "SELECT", "INSERT", "UPDATE", "DELETE", "REPLACE", "MERGE",
    ]

    /// A trigger's event follows these, as in `BEFORE INSERT`, `INSTEAD OF DELETE` and `INSERT OR UPDATE`, so the
    /// word after one is part of the header rather than the body.
    private static let triggerEventLeaders: Set<String> = ["BEFORE", "AFTER", "OF", "OR", "FOR"]

    private static let controlStatementOpeners: Set<String> = ["IF", "WHILE", "LOOP", "REPEAT"]

    private static let handlerKinds: Set<String> = ["CONTINUE", "EXIT", "UNDO"]

    /// The words before a `SET` that is part of MySQL's return type: the `SET(...)` type, `CHARACTER SET`, `CHAR SET`.
    private static let wordsBeforeTypeSet: Set<String> = ["RETURNS", "CHARACTER", "CHAR"]

    private let grammar: SQLLexicalGrammar
    private let readsBlocksEverywhere: Bool
    private let readsCompoundBodies: Bool
    private var openControlStatements: [ControlStatement] = []
    // An `IF` or `WHILE` where a statement can start, until the word that ends its condition at the same depth:
    // `IF(a, 1, 2)` is a function wherever a value can stand.
    private var conditionAwaitingBody: ControlStatement?
    // The `CASE`s open here that are expressions, by the depth inside each: their `THEN` and `ELSE` start no statement.
    private var caseExpressionDepths: [Int] = []
    // Inside PostgreSQL's `BEGIN ATOMIC` body, how far the statement being read is into `CREATE FUNCTION`: only such a
    // statement has a body of its own, and elsewhere `begin atomic` is a column and its alias.
    private var nestedDefinition = NestedDefinition.none
    // A `REPEAT` block just opened, which a `(` right after it turns into the `REPEAT()` function.
    private var repeatMayBeFunction = false
    // A MySQL event's body follows its `DO`, and its schedule before that starts nothing.
    private var awaitsEventBody = false
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
    private var routineBody = RoutineBody.unknown
    private var previousWord: String?
    // A trigger's events stand before its table, as in SQLite's `CREATE TRIGGER tr DELETE ON t`.
    private var readsTriggerEvents = false
    // A trigger's event list goes on after a word in `triggerEventLeaders`, or after a `,` that follows an event, as
    // in `FOR INSERT, UPDATE`.
    private var expectsTriggerEvent = false
    private var followsTriggerEvent = false
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
    private var handler = HandlerPart.none
    private var merge: SQLMergeStatementTracker?

    public init(grammar: SQLLexicalGrammar) {
        self.grammar = grammar
        self.readsBlocksEverywhere = grammar.contains(.unterminatedStatements)
        self.readsCompoundBodies = grammar.contains(.compoundStatementBodies)
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
        repeatMayBeFunction = false
        let previous = previousWord
        previousWord = word
        let isTriggerEvent = expectsTriggerEvent && Self.singleStatementBodyOpeners.contains(word)
        expectsTriggerEvent = Self.triggerEventLeaders.contains(word)
        followsTriggerEvent = isTriggerEvent
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
        let statementPosition = atStatementPosition || readHandlerWord(word)
        observeStatementPosition(after: word, previous: previous, wasAtStatementPosition: statementPosition)
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
        let startsBody = depth == 0 && routineBody == .unknown && !awaitsEventBody
        if !readsBlocksEverywhere, depth == 0 {
            observeBodyStart(word, after: previous, isTriggerEvent: isTriggerEvent)
        }
        let atStatementStart = depth == 0 ? startsBody : statementPosition
        if readsCompoundBodies {
            observeCompoundStatement(word, atStatementStart: atStatementStart)
        }
        if depth > 0, grammar.contains(.atomicRoutineBodies) {
            observeNestedDefinition(word, startsStatement: startsStatement)
        }
        switch word {
        case "BEGIN" where readsBlocksEverywhere:
            pendingBegin = true
            pendingBeginMayOpen = opensNestedBlock(
                atStatementPosition: statementPosition,
                isFirstWord: isFirstWord,
                after: previous
            )
        case "BEGIN":
            if opensNestedBlock(atStatementPosition: statementPosition, isFirstWord: isFirstWord, after: previous) {
                pendingBegin = true
                pendingBeginMayOpen = true
            }
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
            if !atStatementStart {
                caseExpressionDepths.append(depth)
            }
        case "END" where !grammar.hasSingleBodyForm || startsStatement:
            pendingEnd = true
        default:
            break
        }
    }

    public mutating func observeSymbol(_ symbol: UInt16) {
        merge?.observeSymbol(symbol)
        if repeatMayBeFunction {
            repeatMayBeFunction = false
            if symbol == SqlLexer.openParen {
                openControlStatements.removeLast()
                depth -= 1
            }
        }
        previousWord = nil
        readHandlerSymbol(symbol)
        expectsTriggerEvent = symbol == Self.comma && followsTriggerEvent
        followsTriggerEvent = false
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
        repeatMayBeFunction = false
        switch handler {
        case .condition, .sqlState:
            handler = .afterCondition
        case .afterCondition:
            handler = .statement
        default:
            break
        }
        previousWord = nil
        expectsTriggerEvent = false
        followsTriggerEvent = false
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
        repeatMayBeFunction = false
        conditionAwaitingBody = nil
        // A `CASE` that holds a `;` is a statement.
        caseExpressionDepths.removeAll()
        nestedDefinition = .none
        previousWord = nil
        expectsTriggerEvent = false
        followsTriggerEvent = false
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
        handler = .none
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
                readsTriggerEvents = word == "TRIGGER"
                awaitsEventBody = readsCompoundBodies && word == "EVENT"
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

    // A label, `lbl:`, is a word at a statement's start followed by `:`. On MySQL a `DO` where a statement starts is
    // the `DO` statement, an expression after it; any other ends a `WHILE` or `FOR` header.
    private mutating func observeStatementPosition(after word: String, previous: String?, wasAtStatementPosition: Bool) {
        atStatementPosition = depth > 0 && caseExpressionDepths.last != depth && Self.statementIntroducers.contains(word)
            && !(readsCompoundBodies && word == "DO" && wasAtStatementPosition)
        labelMayFollow = wasAtStatementPosition
        if wasAtStatementPosition, word == "DECLARE" {
            inDeclaration = true
        }
        // `handler` is not reserved, so `DECLARE handler CURSOR FOR ...` declares a cursor.
        if inDeclaration, word == "HANDLER", let previous, Self.handlerKinds.contains(previous) {
            handler = .header
        }
    }

    /// Returns whether `word` starts a handler's statement.
    private mutating func readHandlerWord(_ word: String) -> Bool {
        switch handler {
        case .header where word == "FOR":
            handler = .condition
        case .condition where word == "SQLSTATE":
            handler = .sqlState
        case .condition where word == "NOT":
            handler = .notFound
        case .condition, .notFound:
            handler = .afterCondition
        case .afterCondition:
            handler = .statement
            return true
        default:
            break
        }
        return false
    }

    // A MySQL error code arrives one digit at a time.
    private mutating func readHandlerSymbol(_ symbol: UInt16) {
        let isDigit = symbol >= Self.zero && symbol <= Self.nine
        switch handler {
        case .condition:
            handler = .afterCondition
        case .afterCondition where !isDigit:
            handler = symbol == Self.comma ? .condition : .statement
        default:
            break
        }
    }

    private func opensNestedBlock(atStatementPosition: Bool, isFirstWord: Bool, after previous: String?) -> Bool {
        if readsBlocksEverywhere {
            return depth > 0 || definesRoutine || isFirstWord || followsControlFlow || openedBlockBody
        }
        if grammar.contains(.atomicRoutineBodies) { return depth == 0 || nestedDefinition == .routine }
        if grammar.hasSingleBodyForm { return true }
        switch routineBody {
        case .statement:
            return false
        case .returnValue:
            return depth == 0 && (previous == "AS" || previous == "IS")
        case .unknown, .controlStatement:
            // A MySQL body is the one control statement, so a `begin` beside it is a name.
            guard depth > 0 else { return routineBody == .unknown || !readsCompoundBodies }
            return atStatementPosition
        }
    }

    // Where a routine's body is one statement, the word that starts it.
    private mutating func observeBodyStart(_ word: String, after previous: String?, isTriggerEvent: Bool) {
        if word == "ON" {
            readsTriggerEvents = false
        }
        if awaitsEventBody {
            awaitsEventBody = word != "DO"
            return
        }
        guard routineBody == .unknown else { return }
        if Self.controlStatementOpeners.contains(word) {
            routineBody = .controlStatement
        } else if word == "RETURN", previous != "ON" {
            // DB2's `COMMIT ON RETURN NO` is a header clause.
            routineBody = .returnValue
        } else if Self.singleStatementBodyOpeners.contains(word), !isTriggerEvent, !readsTriggerEvents {
            routineBody = .statement
        } else if readsCompoundBodies, word == "SET", !Self.wordsBeforeTypeSet.contains(previous ?? "") {
            routineBody = .statement
        } else if readsCompoundBodies, word == "DO" {
            routineBody = .statement
        }
    }

    // A compound statement opens its block where a statement starts. An `IF` or a `WHILE` opens it only at the word
    // that ends its condition, since a condition holds no statement and `IF(a, 1, 2)` is a function.
    private mutating func observeCompoundStatement(_ word: String, atStatementStart: Bool) {
        guard routineBody == .unknown || routineBody == .controlStatement else { return }
        let awaited = conditionAwaitingBody.flatMap { $0.depth == depth ? $0.keyword : nil }
        switch word {
        case "IF", "WHILE":
            if atStatementStart, conditionAwaitingBody == nil {
                conditionAwaitingBody = ControlStatement(keyword: word, depth: depth)
            }
        case "THEN" where awaited == "IF":
            conditionAwaitingBody = nil
            openControlStatement("IF", startsStatement: true)
        case "DO" where awaited == "WHILE":
            conditionAwaitingBody = nil
            openControlStatement("WHILE", startsStatement: true)
        // MariaDB's Oracle mode writes `WHILE x LOOP ... END LOOP`.
        case "LOOP" where awaited == "WHILE":
            conditionAwaitingBody = nil
            openControlStatement(word, startsStatement: true)
        case "LOOP" where atStatementStart:
            openControlStatement(word, startsStatement: true)
        case "REPEAT" where atStatementStart:
            openControlStatement(word, startsStatement: true)
            repeatMayBeFunction = true
        case "WHEN", "ELSE", "END":
            if awaited != nil {
                conditionAwaitingBody = nil
            }
        default:
            break
        }
    }

    private mutating func observeNestedDefinition(_ word: String, startsStatement: Bool) {
        if startsStatement {
            nestedDefinition = SqlBlockStructure.opensRoutineDefinition(word) ? .opener : .none
        } else if nestedDefinition == .opener, !SqlBlockStructure.precedesRoutineKind(word) {
            nestedDefinition = SqlBlockStructure.isRoutineKind(word, grammar: grammar) ? .routine : .none
        }
    }

    private mutating func openControlStatement(_ keyword: String, startsStatement: Bool) {
        depth += 1
        openControlStatements.append(ControlStatement(keyword: keyword, depth: depth))
        atStatementPosition = startsStatement
    }

    // `END IF` and its kin close the block their own keyword opened, and nothing where it opened none.
    private mutating func closeControlStatement(_ keyword: String) {
        guard let innermost = openControlStatements.last, innermost.keyword == keyword, innermost.depth == depth else {
            return
        }
        openControlStatements.removeLast()
        depth -= 1
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
            closeControlStatement(word)
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
        if routineBody == .returnValue {
            routineBody = .unknown
        }
        depth += 1
        openedBlockBody = true
        startsBodyStatement = true
        atStatementPosition = true
        nestedDefinition = .none
    }

    private mutating func closeBlock() {
        depth = max(0, depth - 1)
        openCaseExpressions = max(0, openCaseExpressions - 1)
        openControlStatements.removeAll { $0.depth > depth }
        caseExpressionDepths.removeAll { $0 > depth }
    }
}
