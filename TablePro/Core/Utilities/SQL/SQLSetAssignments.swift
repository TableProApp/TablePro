//
//  SQLSetAssignments.swift
//  TablePro
//

import Foundation

/// One `name = value` element of a `SET` statement, as it was written.
///
/// `spelledWithAtAt` is load-bearing rather than cosmetic: MySQL reads `SET @@transaction_isolation`
/// as the next transaction's characteristics and refuses it inside one, while `SET SESSION
/// transaction_isolation` sets the session variable and is allowed.
internal struct SQLSetAssignment: Equatable, Sendable {
    internal enum Scope: Equatable, Sendable {
        case unspecified
        case session
        case local
        case global
        case persist
        case persistOnly
    }

    internal let scope: Scope
    internal let name: String
    internal let spelledWithAtAt: Bool
}

/// Reads the targets of a `SET`, with the cursor positioned just past the `SET` keyword.
///
/// Values are skipped to the next depth-0 comma rather than parsed, so a comma inside parentheses
/// or inside a string never splits an element. An element that is not an assignment (`SET NAMES
/// utf8mb4`, `SET CHARACTER SET x`) and a user variable (`SET @x = 1`) yield nothing while the rest
/// of the list is still read: `mysqlbinlog` writes the assignment that matters fourth.
///
/// MySQL applies the most recent `GLOBAL`/`SESSION` keyword to every following element that carries
/// no modifier of its own, which is why the scope is carried across the list.
internal enum SQLSetAssignments {
    private static let scopeKeywords: [String: SQLSetAssignment.Scope] = [
        "SESSION": .session,
        "LOCAL": .local,
        "GLOBAL": .global,
        "PERSIST": .persist,
        "PERSIST_ONLY": .persistOnly
    ]

    private static let atAtScopes: [String: SQLSetAssignment.Scope] = [
        "SESSION": .session,
        "LOCAL": .local,
        "GLOBAL": .global
    ]

    internal static func assignments(from cursor: inout SQLTokenCursor, readsList: Bool) -> [SQLSetAssignment] {
        var head = cursor.next()
        var stopsAtFor = false
        if head?.word == "STATEMENT" {
            stopsAtFor = true
            head = cursor.next()
        }

        var assignments: [SQLSetAssignment] = []
        var listScope = SQLSetAssignment.Scope.unspecified
        while let token = head {
            if let assignment = element(startingAt: token, cursor: &cursor, listScope: &listScope) {
                assignments.append(assignment)
            }
            guard readsList else { break }
            head = nextElementHead(cursor: &cursor, stopsAtFor: stopsAtFor)
        }
        return assignments
    }

    private static func element(
        startingAt token: SQLTokenCursor.Token,
        cursor: inout SQLTokenCursor,
        listScope: inout SQLSetAssignment.Scope
    ) -> SQLSetAssignment? {
        var current = token
        while let word = current.word, let scope = scopeKeywords[word] {
            listScope = scope
            guard let next = cursor.next() else { return nil }
            current = next
        }
        guard let assignment = target(current, cursor: &cursor, listScope: listScope) else { return nil }
        guard cursor.next()?.isSymbol(SQLTokenCursor.equals) == true else { return nil }
        return assignment
    }

    private static func target(
        _ token: SQLTokenCursor.Token,
        cursor: inout SQLTokenCursor,
        listScope: SQLSetAssignment.Scope
    ) -> SQLSetAssignment? {
        guard let word = token.word else {
            guard let name = token.identifier else { return nil }
            return SQLSetAssignment(scope: listScope, name: name, spelledWithAtAt: false)
        }
        guard word.hasPrefix("@") else {
            return SQLSetAssignment(scope: listScope, name: word, spelledWithAtAt: false)
        }
        guard word.hasPrefix("@@") else { return nil }
        return systemVariable(named: String(word.dropFirst(2)), cursor: &cursor)
    }

    private static func systemVariable(named name: String, cursor: inout SQLTokenCursor) -> SQLSetAssignment? {
        guard let scope = atAtScopes[name] else {
            return SQLSetAssignment(scope: .unspecified, name: name, spelledWithAtAt: true)
        }
        var lookahead = cursor
        guard lookahead.next()?.isSymbol(SQLTokenCursor.period) == true,
              let qualified = lookahead.next()?.identifier
        else {
            return SQLSetAssignment(scope: .unspecified, name: name, spelledWithAtAt: true)
        }
        cursor = lookahead
        return SQLSetAssignment(scope: scope, name: qualified, spelledWithAtAt: true)
    }

    private static func nextElementHead(
        cursor: inout SQLTokenCursor,
        stopsAtFor: Bool
    ) -> SQLTokenCursor.Token? {
        while let token = cursor.next() {
            guard cursor.parenDepth == 0 else { continue }
            if stopsAtFor, token.word == "FOR" { return nil }
            guard token.isSymbol(SQLTokenCursor.comma) else { continue }
            return cursor.next()
        }
        return nil
    }
}
