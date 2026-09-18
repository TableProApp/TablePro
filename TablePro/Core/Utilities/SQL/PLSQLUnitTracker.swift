//
//  PLSQLUnitTracker.swift
//  TablePro
//

import Foundation

/// Statement boundaries in Oracle's language, where a `;` inside a PL/SQL unit separates the unit's own statements.
///
/// A statement's first words say what it is, the way SQL*Plus decides whether to enter PL/SQL mode:
///
/// - `DECLARE`, `BEGIN` and a labelled block are anonymous PL/SQL blocks.
/// - `CREATE [OR REPLACE] [EDITIONABLE | NONEDITIONABLE]` followed by `PROCEDURE`, `FUNCTION`, `PACKAGE [BODY]`,
///   `TYPE [BODY]`, `TRIGGER` or `LIBRARY` is a stored unit.
/// - `WITH FUNCTION` or `WITH PROCEDURE` is SQL whose `WITH` clause declares PL/SQL, so each declaration's `END;` is
///   inside the statement and only the query after them ends it.
/// - `CREATE JAVA` and `CREATE MLE MODULE` carry source in another language after `AS`, which only a `/` line or the
///   end of the script can end. So does a unit whose body is `WRAPPED`.
/// - Everything else is SQL, and its first `;` ends it.
///
/// Inside a unit the tracker counts the constructs that one bare `END` closes: a block, a subprogram or package body,
/// a compound trigger and a `CASE`. A `BEGIN` continues the innermost construct when that construct is still in its
/// declaration section, because `DECLARE ... BEGIN ... END` and `PROCEDURE p IS ... BEGIN ... END` each end once.
/// `END IF` and `END LOOP` close constructs that never opened one, and a word after `.` is a member name, never a
/// keyword. A `;` ends the unit only once every construct has closed.
///
/// The final `;` of a unit belongs to it, except after a trigger whose body is a `CALL`: measured on Oracle 23ai,
/// `CREATE TRIGGER ... CALL p(:NEW.a);` is stored INVALID and the same text without the `;` compiles.
/// `scripts/check-oracle-plsql-terminators.sh` re-measures both rules against a live server.
struct PLSQLUnitTracker: SQLStatementBoundaryTracking {
    private enum Lead {
        case start
        case afterCreate
        case afterCreateType
        case afterWith
        case decided
    }

    private enum Kind {
        case sql
        case anonymousBlock
        case storedUnit
        case inlineDeclarations
        case embeddedSourceHeader
        case opaque
    }

    private enum Header {
        case subprogram
        case unitBody
        case trigger
        case embeddedSource
    }

    private static let lessThan = UInt16(UnicodeScalar("<").value)
    private static let greaterThan = UInt16(UnicodeScalar(">").value)
    private static let period = UInt16(UnicodeScalar(".").value)

    private static let createModifiers: Set<String> = [
        "OR", "REPLACE", "EDITIONABLE", "NONEDITIONABLE", "AND", "RESOLVE", "COMPILE", "NOFORCE",
    ]

    private var lead = Lead.start
    private var kind = Kind.sql
    private var header: Header?

    /// One entry per construct a bare `END` will close, true while that construct still waits for its `BEGIN`.
    private var constructs: [Bool] = []
    private var parenDepth = 0
    private var pendingEnd = false
    private var pendingBodyKeyword = false
    private var followsPeriod = false
    private var previousSymbol: UInt16?
    private var inLabel = false
    private var callsRoutine = false
    private var expectsDeclaration = false
    private var inlineQueryStarted = false

    var needsWords: Bool {
        lead != .decided || tracksConstructs
    }

    var terminator: SQLStatementTerminator {
        switch kind {
        case .anonymousBlock, .opaque:
            return .partOfStatement
        case .storedUnit:
            return callsRoutine ? .separator : .partOfStatement
        case .sql, .inlineDeclarations, .embeddedSourceHeader:
            return .separator
        }
    }

    var acceptsBindParameters: Bool {
        switch kind {
        case .storedUnit, .embeddedSourceHeader, .opaque:
            return false
        case .sql, .anonymousBlock, .inlineDeclarations:
            return true
        }
    }

    mutating func observeWord(_ word: String) {
        previousSymbol = nil
        guard !inLabel else { return }
        let isMember = followsPeriod
        followsPeriod = false

        switch lead {
        case .start:
            decideLead(word)
            return
        case .afterCreate:
            continueCreate(word)
            return
        case .afterCreateType:
            lead = .decided
            header = word == "BODY" ? .unitBody : nil
            return
        case .afterWith:
            lead = .decided
            if word == "FUNCTION" || word == "PROCEDURE" {
                kind = .inlineDeclarations
                header = .subprogram
            }
            return
        case .decided:
            break
        }

        guard tracksConstructs, !isMember, !word.hasPrefix("$") else { return }
        if pendingEnd {
            pendingEnd = false
            if closeEnd(followedBy: word) { return }
        }
        if pendingBodyKeyword {
            pendingBodyKeyword = false
            header = nil
            if word == "LANGUAGE" || word == "EXTERNAL" { return }
            constructs.append(true)
        }
        if expectsDeclaration {
            expectsDeclaration = false
            guard word == "FUNCTION" || word == "PROCEDURE" else {
                inlineQueryStarted = true
                return
            }
        }
        if let header {
            if parenDepth == 0 {
                observeHeaderWord(word, in: header)
            }
            return
        }
        observeBodyWord(word)
    }

    mutating func observeSymbol(_ symbol: UInt16) {
        if symbol == Self.lessThan, previousSymbol == Self.lessThan {
            inLabel = true
            previousSymbol = nil
            return
        }
        if symbol == Self.greaterThan, previousSymbol == Self.greaterThan, inLabel {
            inLabel = false
            previousSymbol = nil
            return
        }
        previousSymbol = symbol
        guard !inLabel, tracksConstructs else { return }
        settlePendingBeforeNonWord()
        switch symbol {
        case SqlLexer.openParen:
            parenDepth += 1
        case SqlLexer.closeParen:
            parenDepth = max(0, parenDepth - 1)
        default:
            break
        }
        followsPeriod = symbol == Self.period
    }

    mutating func observeOpaqueToken() {
        previousSymbol = nil
        followsPeriod = false
        guard tracksConstructs else { return }
        settlePendingBeforeNonWord()
    }

    mutating func observeSemicolon() -> Bool {
        previousSymbol = nil
        followsPeriod = false
        guard lead == .decided else { return true }

        switch kind {
        case .sql, .embeddedSourceHeader:
            return true
        case .opaque:
            return false
        case .anonymousBlock, .storedUnit:
            settlePendingBeforeNonWord()
            endForwardDeclaration()
            return constructs.isEmpty
        case .inlineDeclarations:
            guard !inlineQueryStarted else { return true }
            settlePendingBeforeNonWord()
            endForwardDeclaration()
            if constructs.isEmpty {
                expectsDeclaration = true
            }
            return false
        }
    }

    mutating func reset() {
        self = PLSQLUnitTracker()
    }

    // MARK: - Private

    private var tracksConstructs: Bool {
        guard lead == .decided else { return false }
        switch kind {
        case .anonymousBlock, .storedUnit, .embeddedSourceHeader:
            return true
        case .inlineDeclarations:
            return !inlineQueryStarted
        case .sql, .opaque:
            return false
        }
    }

    private mutating func decideLead(_ word: String) {
        switch word {
        case "DECLARE":
            lead = .decided
            kind = .anonymousBlock
            constructs.append(true)
        case "BEGIN":
            lead = .decided
            kind = .anonymousBlock
            constructs.append(false)
        case "CREATE":
            lead = .afterCreate
        case "WITH":
            lead = .afterWith
        default:
            lead = .decided
        }
    }

    private mutating func continueCreate(_ word: String) {
        guard !Self.createModifiers.contains(word) else { return }
        lead = .decided
        switch word {
        case "PROCEDURE", "FUNCTION":
            kind = .storedUnit
            header = .subprogram
        case "PACKAGE":
            kind = .storedUnit
            header = .unitBody
        case "TRIGGER":
            kind = .storedUnit
            header = .trigger
        case "TYPE":
            kind = .storedUnit
            lead = .afterCreateType
        case "LIBRARY":
            kind = .storedUnit
        case "JAVA", "MLE":
            kind = .embeddedSourceHeader
            header = .embeddedSource
        default:
            break
        }
    }

    private mutating func observeHeaderWord(_ word: String, in header: Header) {
        if word == "WRAPPED", header != .embeddedSource {
            kind = .opaque
            self.header = nil
            return
        }
        switch header {
        case .subprogram:
            if word == "IS" || word == "AS" {
                pendingBodyKeyword = true
            }
        case .unitBody:
            if word == "IS" || word == "AS" {
                self.header = nil
                constructs.append(true)
            }
        case .trigger:
            observeTriggerHeaderWord(word)
        case .embeddedSource:
            if word == "AS" {
                kind = .opaque
                self.header = nil
            }
        }
    }

    private mutating func observeTriggerHeaderWord(_ word: String) {
        switch word {
        case "DECLARE":
            header = nil
            constructs.append(true)
        case "BEGIN", "COMPOUND":
            header = nil
            constructs.append(false)
        case "CALL":
            header = nil
            callsRoutine = true
        default:
            break
        }
    }

    private mutating func observeBodyWord(_ word: String) {
        switch word {
        case "BEGIN":
            if constructs.last == true {
                constructs[constructs.count - 1] = false
            } else {
                constructs.append(false)
            }
        case "DECLARE":
            constructs.append(true)
        case "CASE":
            constructs.append(false)
        case "END":
            pendingEnd = true
        case "PROCEDURE", "FUNCTION":
            if parenDepth == 0 {
                header = .subprogram
            }
        default:
            break
        }
    }

    /// Returns whether `word` was consumed by the `END` before it.
    private mutating func closeEnd(followedBy word: String) -> Bool {
        switch SqlBlockStructure.endingFollowedBy(word) {
        case .closesControlFlow:
            return true
        case .closesCaseStatement:
            closeConstruct()
            return true
        case .closesBlock:
            closeConstruct()
            return false
        }
    }

    private mutating func settlePendingBeforeNonWord() {
        if pendingEnd {
            pendingEnd = false
            closeConstruct()
        }
        if pendingBodyKeyword {
            pendingBodyKeyword = false
            header = nil
            constructs.append(true)
        }
    }

    /// A subprogram header ended by `;` rather than `IS` or `AS` is a forward declaration or a package
    /// specification entry, and opened nothing.
    private mutating func endForwardDeclaration() {
        guard header == .subprogram, parenDepth == 0 else { return }
        header = nil
    }

    private mutating func closeConstruct() {
        guard !constructs.isEmpty else { return }
        constructs.removeLast()
    }
}
