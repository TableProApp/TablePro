//
//  SQLiteColumnDeclaration.swift
//  TableProPluginKit
//

import Foundation

/// One column definition inside a stored `CREATE TABLE`, split into the parts an edit can replace.
///
/// SQLite has no `ALTER TABLE` for a column's type, nullability or default, so changing one means
/// recreating the table. The rebuild keeps every untouched column's source text byte for byte, and
/// a column the save *does* touch has to be rewritten the same way: replace the span that changed
/// and leave the rest of what the user wrote alone. Re-rendering the whole declaration from a model
/// would lose the `CHECK`, the `COLLATE`, the `GENERATED ALWAYS AS` and the `REFERENCES` that no
/// catalog query reports.
///
/// The declaration is read as a grammar rather than searched for keywords, because searching is
/// wrong in both directions and silently so. Measured on 3.54: in
/// `b TEXT CHECK (b IS NOT NULL)` a search for `NOT NULL` matches inside the check, so the column
/// reads as already non-null and "make it NOT NULL" does nothing; in
/// `a INTEGER REFERENCES p(id) ON DELETE SET NULL` a search for `NULL` matches inside the foreign
/// key's action, so "make it nullable" rewrites the action into a syntax error. Walking the
/// constraint list left to right and consuming each constraint whole is the only way to know which
/// `NULL` is which.
public struct SQLiteColumnDeclaration: Equatable {
    /// What a constraint in the list is, as far as an edit needs to care.
    public enum ConstraintKind: Equatable {
        case primaryKey
        /// `NOT NULL`.
        case notNull
        /// A bare `NULL`, which states the default nullability rather than changing it.
        case null
        case unique
        case check
        case defaultValue
        case collate
        case foreignKey
        /// `GENERATED ALWAYS AS (…)` or its `AS (…)` short form.
        case generated
    }

    public struct Constraint: Equatable {
        public let kind: ConstraintKind
        /// The whole constraint, including any `CONSTRAINT name` that introduces it. Removing one
        /// has to take the name with it, or the orphan is dead text at best and a parse error at
        /// worst.
        public let range: Range<String.Index>

        /// The clause without its `CONSTRAINT name`. Replacing a clause writes here, so a key the
        /// user named keeps the name they gave it and stays droppable by that name.
        public let clauseRange: Range<String.Index>
    }

    /// The column's own name, as written.
    public let name: String
    public let nameRange: Range<String.Index>

    /// The declared type. Nil where the column has none, which SQLite allows: `CREATE TABLE t(a)`.
    public let typeRange: Range<String.Index>?

    /// The declared type as written, so a decision about it needs no second look at the source.
    public let declaredType: String?

    public let constraints: [Constraint]

    public func first(_ kind: ConstraintKind) -> Constraint? {
        constraints.first { $0.kind == kind }
    }

    public var isGenerated: Bool { first(.generated) != nil }
}

public extension SQLiteColumnDeclaration {
    /// Reads a column definition, or nil for an entry that is a table constraint rather than a
    /// column, or one this grammar does not fully understand.
    ///
    /// Refusing to parse is the safe answer: the rebuild that would have used the result refuses
    /// with it, and the user is told to write the SQL themselves rather than shown a table rebuilt
    /// from a guess.
    static func parse(_ text: String) -> SQLiteColumnDeclaration? {
        let tokens = SQLiteTokenizer.tokenize(text)
        guard let first = tokens.first, !first.isPunctuation, !first.text.isEmpty else { return nil }
        guard !SQLiteColumnGrammar.tableConstraintKeywords.contains(first.keyword) else { return nil }

        let typeEnd = SQLiteColumnGrammar.endOfTypeName(tokens, from: 1)
        let typeRange = typeEnd > 1
            ? tokens[1].range.lowerBound..<tokens[typeEnd - 1].range.upperBound
            : nil

        guard let constraints = SQLiteColumnGrammar.constraints(tokens, from: typeEnd) else { return nil }

        return SQLiteColumnDeclaration(
            name: first.text,
            nameRange: first.range,
            typeRange: typeRange,
            declaredType: typeRange.map { String(text[$0]) },
            constraints: constraints
        )
    }

    /// What a save asks to change about one column. A nil field is left exactly as it was.
    struct Edit: Sendable, Equatable {
        /// The new type, or an empty string to remove the type entirely.
        public var type: String?
        public var isNullable: Bool?
        /// The new default as SQL, or an empty string to remove the `DEFAULT` clause.
        public var defaultValue: String?

        public init(type: String? = nil, isNullable: Bool? = nil, defaultValue: String? = nil) {
            self.type = type
            self.isNullable = isNullable
            self.defaultValue = defaultValue
        }

        public var isEmpty: Bool { type == nil && isNullable == nil && defaultValue == nil }
    }

    /// The declaration with `edit` applied and everything else byte for byte as it was.
    ///
    /// Nil when the edit cannot be made without guessing: a generated column's nullability and
    /// default are the expression's to decide, and a declaration this grammar could not read whole
    /// is never rewritten from a partial understanding.
    /// - Parameter isRowidAlias: whether this column *is* the table's rowid, which the declaration
    ///   alone cannot say: the primary key may be written at table level.
    static func rewritten(_ text: String, applying edit: Edit, isRowidAlias: Bool = false) -> String? {
        guard !edit.isEmpty else { return text }
        guard let declaration = parse(text),
              declaration.canApply(edit, isRowidAlias: isRowidAlias) else { return nil }

        /// Every replacement is computed against the original text and applied last-first, so an
        /// earlier edit never moves the indices a later one was measured from.
        var replacements: [(Range<String.Index>, String)] = []

        if let type = edit.type {
            let rendered = type.trimmingCharacters(in: .whitespacesAndNewlines)
            if let typeRange = declaration.typeRange {
                replacements.append((typeRange, rendered))
            } else if !rendered.isEmpty {
                replacements.append((declaration.nameRange.upperBound..<declaration.nameRange.upperBound, " \(rendered)"))
            }
        }

        if let isNullable = edit.isNullable {
            let existing = declaration.first(.notNull) ?? declaration.first(.null)
            if isNullable {
                /// A bare `NULL` says what SQLite would do anyway, so removing the constraint and
                /// removing only the `NOT` both land in the same place. The whole clause goes.
                if let existing, existing.kind == .notNull { replacements.append((existing.range, "")) }
            } else if let existing, existing.kind == .null {
                replacements.append((existing.clauseRange, "NOT NULL"))
            } else if declaration.first(.notNull) == nil {
                replacements.append((insertionPoint(in: declaration)..<insertionPoint(in: declaration), " NOT NULL"))
            }
        }

        if let defaultValue = edit.defaultValue {
            let rendered = defaultValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let clause = rendered.isEmpty ? "" : "DEFAULT \(rendered)"
            if let existing = declaration.first(.defaultValue) {
                /// Replacing writes inside the clause so a `CONSTRAINT d DEFAULT 1` keeps its name;
                /// removing takes the whole thing, name included.
                replacements.append((clause.isEmpty ? existing.range : existing.clauseRange, clause))
            } else if !clause.isEmpty {
                replacements.append((insertionPoint(in: declaration)..<insertionPoint(in: declaration), " \(clause)"))
            }
        }

        return apply(replacements, to: text)
    }

    /// Whether `edit` can be made to this column without changing something it did not ask about.
    ///
    /// Every no here is a case where the rewrite would succeed and be wrong, so it refuses and the
    /// user is told to write the SQL themselves.
    private func canApply(_ edit: Edit, isRowidAlias: Bool) -> Bool {
        /// A generated column's nullability and default belong to its expression, and SQLite
        /// rejects a `DEFAULT` on one outright.
        if isGenerated, edit.isNullable != nil || edit.defaultValue != nil { return false }

        /// `a INT NOT NULL NOT NULL` and `a INT DEFAULT 1 DEFAULT 2` are both legal, measured.
        /// Rewriting one of a pair leaves the other in force, so the edit would report success and
        /// change nothing.
        if edit.isNullable != nil,
           constraints.filter({ $0.kind == .notNull || $0.kind == .null }).count > 1 { return false }
        if edit.defaultValue != nil, constraints.filter({ $0.kind == .defaultValue }).count > 1 { return false }

        /// Retyping a column that carries an inline `PRIMARY KEY` away from `INTEGER` destroys the
        /// rowid alias. Measured: the key stops generating values and then stores NULL on every
        /// insert that omits it, silently, twice over. `AUTOINCREMENT` is refused by SQLite itself
        /// in that position, but a plain `INTEGER PRIMARY KEY` is not.
        if let type = edit.type, isRowidAlias || (first(.primaryKey) != nil && isIntegerTyped),
           !type.trimmingCharacters(in: .whitespaces).isEmpty,
           type.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("INTEGER") != .orderedSame {
            return false
        }
        return true
    }

    private var isIntegerTyped: Bool {
        declaredType?.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("INTEGER") == .orderedSame
    }

    /// Where a constraint the declaration does not have is written: after the type, or after the
    /// name when there is none. Before every existing constraint, so a `REFERENCES` clause and its
    /// actions stay contiguous.
    private static func insertionPoint(in declaration: SQLiteColumnDeclaration) -> String.Index {
        declaration.typeRange?.upperBound ?? declaration.nameRange.upperBound
    }

    /// Applies the replacements last-first so an earlier edit never moves the indices a later one
    /// was measured from.
    ///
    /// Two insertions can land on the same index, which happens whenever a save adds both a
    /// nullability and a default to a column that had neither. Ordering by position alone leaves
    /// their relative order to the sort, so the position is paired with the order they were
    /// collected in and the result is the same every time.
    private static func apply(_ replacements: [(Range<String.Index>, String)], to text: String) -> String {
        var result = text
        let ordered = replacements.enumerated().sorted {
            $0.element.0.lowerBound == $1.element.0.lowerBound
                ? $0.offset > $1.offset
                : $0.element.0.lowerBound > $1.element.0.lowerBound
        }
        for (range, value) in ordered.map(\.element) {
            if value.isEmpty {
                result = SQLiteTableDDL.cuttingSpan(range, from: result)
            } else {
                result.replaceSubrange(range, with: value)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The column-definition grammar, as SQLite accepts it rather than as its railroad diagrams read.
internal enum SQLiteColumnGrammar {
    /// What may begin a table constraint, so an entry that starts with one is not a column.
    internal static let tableConstraintKeywords: Set<String> = [
        "CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN"
    ]

    /// The keywords that end a type name by starting a column constraint.
    ///
    /// Measured against 3.54 by declaring `a BIG <keyword>` and reading the type back. `GENERATED`
    /// and `ALWAYS` are absent on purpose: alone they are absorbed into the type, and only the
    /// exact run `GENERATED ALWAYS AS` terminates it. `KEY`, `ASC`, `DESC`, `STORED`, `VIRTUAL`,
    /// `CONFLICT`, `MATCH` and `ROWID` are absorbed the same way.
    private static let constraintFirst: Set<String> = [
        "CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK",
        "DEFAULT", "COLLATE", "REFERENCES", "AS", "DEFERRABLE"
    ]

    private static let conflictActions: Set<String> = ["ROLLBACK", "ABORT", "FAIL", "IGNORE", "REPLACE"]

    /// The index just past the type name, starting from `index`.
    ///
    /// A type name is one or more names, each of which may be quoted, optionally followed by a
    /// parenthesised pair of signed numbers. `CREATE TABLE t(a)` declares no type at all, and
    /// `UNSIGNED BIG INT` and `VARYING CHARACTER(255)` are both one type.
    internal static func endOfTypeName(_ tokens: [SQLiteToken], from index: Int) -> Int {
        var cursor = index
        while cursor < tokens.count {
            let token = tokens[cursor]
            if token.text == "(" {
                guard let close = matchingParen(tokens, from: cursor) else { return cursor }
                cursor = close + 1
                break
            }
            if token.isPunctuation { break }
            if startsGeneratedClause(tokens, at: cursor) { break }
            if constraintFirst.contains(token.keyword) { break }
            cursor += 1
        }
        return cursor
    }

    /// Every constraint after the type, in order, or nil where one could not be read whole.
    internal static func constraints(
        _ tokens: [SQLiteToken],
        from index: Int
    ) -> [SQLiteColumnDeclaration.Constraint]? {
        var found: [SQLiteColumnDeclaration.Constraint] = []
        var cursor = index

        while cursor < tokens.count {
            let start = cursor
            /// `CONSTRAINT name` introduces whichever constraint follows, so it belongs to that
            /// one's span: removing the constraint has to take its name with it.
            if tokens[cursor].keyword == "CONSTRAINT" {
                guard cursor + 1 < tokens.count else { return nil }
                cursor += 2
                guard cursor < tokens.count else { return nil }
            }

            guard let (kind, end) = constraint(tokens, from: cursor) else { return nil }
            found.append(
                SQLiteColumnDeclaration.Constraint(
                    kind: kind,
                    range: tokens[start].range.lowerBound..<tokens[end - 1].range.upperBound,
                    clauseRange: tokens[cursor].range.lowerBound..<tokens[end - 1].range.upperBound
                )
            )
            cursor = end
        }
        return found
    }

    /// One constraint and the index just past it.
    private static func constraint(_ tokens: [SQLiteToken], from index: Int) -> (SQLiteColumnDeclaration.ConstraintKind, Int)? {
        var cursor = index
        switch tokens[cursor].keyword {
        case "PRIMARY":
            guard cursor + 1 < tokens.count, tokens[cursor + 1].keyword == "KEY" else { return nil }
            cursor += 2
            if cursor < tokens.count, ["ASC", "DESC"].contains(tokens[cursor].keyword) { cursor += 1 }
            cursor = skipConflictClause(tokens, from: cursor)
            if cursor < tokens.count, tokens[cursor].keyword == "AUTOINCREMENT" { cursor += 1 }
            return (.primaryKey, cursor)

        case "NOT":
            guard cursor + 1 < tokens.count, tokens[cursor + 1].keyword == "NULL" else { return nil }
            return (.notNull, skipConflictClause(tokens, from: cursor + 2))

        case "NULL":
            return (.null, skipConflictClause(tokens, from: cursor + 1))

        case "UNIQUE":
            return (.unique, skipConflictClause(tokens, from: cursor + 1))

        case "CHECK":
            guard cursor + 1 < tokens.count, tokens[cursor + 1].text == "(",
                  let close = matchingParen(tokens, from: cursor + 1) else { return nil }
            return (.check, close + 1)

        case "DEFAULT":
            cursor += 1
            guard cursor < tokens.count else { return nil }
            if tokens[cursor].text == "(" {
                guard let close = matchingParen(tokens, from: cursor) else { return nil }
                return (.defaultValue, close + 1)
            }
            guard let end = endOfDefaultLiteral(tokens, from: cursor) else { return nil }
            return (.defaultValue, end)

        case "COLLATE":
            guard cursor + 1 < tokens.count else { return nil }
            return (.collate, cursor + 2)

        case "REFERENCES":
            guard let end = SQLiteForeignKeyParser.referenceEnd(tokens, from: cursor) else { return nil }
            return (.foreignKey, end + 1)

        case "GENERATED", "AS":
            guard let end = endOfGeneratedClause(tokens, from: cursor) else { return nil }
            return (.generated, end)

        default:
            return nil
        }
    }

    private static func startsGeneratedClause(_ tokens: [SQLiteToken], at index: Int) -> Bool {
        guard index + 2 < tokens.count else { return false }
        return tokens[index].keyword == "GENERATED"
            && tokens[index + 1].keyword == "ALWAYS"
            && tokens[index + 2].keyword == "AS"
    }

    /// `GENERATED ALWAYS AS ( expr ) [STORED | VIRTUAL]`, or the same from a bare `AS`.
    private static func endOfGeneratedClause(_ tokens: [SQLiteToken], from index: Int) -> Int? {
        var cursor = index
        if tokens[cursor].keyword == "GENERATED" {
            guard startsGeneratedClause(tokens, at: cursor) else { return nil }
            cursor += 3
        } else {
            cursor += 1
        }
        guard cursor < tokens.count, tokens[cursor].text == "(",
              let close = matchingParen(tokens, from: cursor) else { return nil }
        cursor = close + 1
        if cursor < tokens.count, ["STORED", "VIRTUAL"].contains(tokens[cursor].keyword) { cursor += 1 }
        return cursor
    }

    /// The index just past a default's literal operand.
    ///
    /// The tokenizer splits on punctuation, so a single SQLite literal can arrive as several
    /// tokens: `0.5` comes back as `0`, `.`, `5`, and `X'0102'` as `X` and a string literal.
    /// Consuming one token would leave the remainder to be read as an unknown constraint, which
    /// refuses every edit on a column carrying one of these very ordinary defaults.
    private static func endOfDefaultLiteral(_ tokens: [SQLiteToken], from index: Int) -> Int? {
        var cursor = index
        if ["+", "-"].contains(tokens[cursor].text) { cursor += 1 }
        guard cursor < tokens.count else { return nil }

        /// A blob literal is the letter x followed by a quoted run.
        if tokens[cursor].keyword == "X", cursor + 1 < tokens.count, tokens[cursor + 1].isStringLiteral {
            return cursor + 2
        }

        cursor += 1
        /// The fractional part and an exponent, each of which the tokenizer has split off.
        if cursor < tokens.count, tokens[cursor].text == "." {
            cursor += 1
            if cursor < tokens.count, !tokens[cursor].isPunctuation { cursor += 1 }
        }
        if cursor + 1 < tokens.count, ["E", "e"].contains(tokens[cursor].text) {
            var lookahead = cursor + 1
            if ["+", "-"].contains(tokens[lookahead].text) { lookahead += 1 }
            if lookahead < tokens.count, !tokens[lookahead].isPunctuation { cursor = lookahead + 1 }
        }
        return cursor
    }

    private static func skipConflictClause(_ tokens: [SQLiteToken], from index: Int) -> Int {
        guard index + 2 < tokens.count,
              tokens[index].keyword == "ON", tokens[index + 1].keyword == "CONFLICT",
              conflictActions.contains(tokens[index + 2].keyword) else { return index }
        return index + 3
    }

    /// The index of the `)` closing the `(` at `index`.
    private static func matchingParen(_ tokens: [SQLiteToken], from index: Int) -> Int? {
        guard tokens[index].text == "(" else { return nil }
        var depth = 0
        var cursor = index
        while cursor < tokens.count {
            if tokens[cursor].text == "(" { depth += 1 }
            if tokens[cursor].text == ")" {
                depth -= 1
                if depth == 0 { return cursor }
            }
            cursor += 1
        }
        return nil
    }
}
