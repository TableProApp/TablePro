//
//  SQLExportDDLRewriter.swift
//  SQLExportPlugin
//

import Foundation
import TableProPluginKit

/// Removes the clauses that pin a CREATE statement to the server it was read from: the table's
/// `AUTO_INCREMENT` counter and a view's `DEFINER` account. Both are MySQL's own spelling, so every
/// other dialect is handed back untouched.
///
/// Each clause is recognised only in the one position its grammar puts it. The counter is a table
/// option, so it is taken at parenthesis depth zero alone; the account belongs to the CREATE header,
/// so it is taken between `CREATE` and the object keyword alone. Without that, a column named
/// `auto_increment` or `definer` in a CHECK constraint is stripped out of its own expression, which
/// SQLite reports verbatim from its catalog and PostgreSQL renders from `pg_get_constraintdef`:
/// `CHECK (auto_increment = 4)` came back as `CHECK ()`.
///
/// The scan is quote-aware for the same reason. A `SHOW CREATE TABLE` reports a column COMMENT and a
/// quoted column name as the schema wrote them, so a table carrying `AUTO_INCREMENT=5` in either has
/// its own data rewritten by anything that cannot see quoting.
///
/// Only the clause forms carry `=`. The column-level `AUTO_INCREMENT` attribute and
/// `SQL SECURITY DEFINER` do not, so both survive: dropping the latter, as `mysqlpump --skip-definer`
/// does, would turn a view declared `SQL SECURITY INVOKER` into a definer-rights view.
internal struct SQLExportDDLRewriter {
    internal let dialect: SqlDialect
    internal let excludesAutoIncrementValue: Bool
    internal let excludesDefiner: Bool

    private struct ScanState {
        var parenthesisDepth = 0
        var isInCreateHeader = false
    }

    internal func rewrite(_ ddl: String) -> String {
        guard dialect == .mysql, excludesAutoIncrementValue || excludesDefiner else { return ddl }

        let characters = Array(ddl)
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var state = ScanState()
        var index = 0

        while index < characters.count {
            if let quoted = Self.quotedRunEnd(in: characters, from: index) {
                output.append(contentsOf: characters[index ..< quoted])
                index = quoted
                continue
            }
            if let commented = Self.commentRunEnd(in: characters, from: index) {
                output.append(contentsOf: characters[index ..< commented])
                index = commented
                continue
            }
            guard Self.isWordCharacter(characters[index]) else {
                Self.track(characters[index], in: &state)
                output.append(characters[index])
                index += 1
                continue
            }

            var wordEnd = index
            while wordEnd < characters.count, Self.isWordCharacter(characters[wordEnd]) {
                wordEnd += 1
            }
            let keyword = String(characters[index ..< wordEnd]).uppercased()

            if let clauseEnd = clauseEnd(keyword: keyword, in: characters, assignmentStart: wordEnd, state: state) {
                index = Self.closeGap(in: characters, after: clauseEnd, output: &output)
                continue
            }

            Self.track(keyword, in: &state)
            output.append(contentsOf: characters[index ..< wordEnd])
            index = wordEnd
        }

        return String(output)
    }

    private func clauseEnd(
        keyword: String,
        in characters: [Character],
        assignmentStart: Int,
        state: ScanState
    ) -> Int? {
        switch keyword {
        case "AUTO_INCREMENT" where excludesAutoIncrementValue && state.parenthesisDepth == 0:
            Self.assignedValueEnd(in: characters, from: assignmentStart, value: Self.digitRunEnd)
        case "DEFINER" where excludesDefiner && state.isInCreateHeader:
            Self.assignedValueEnd(in: characters, from: assignmentStart, value: Self.accountEnd)
        default:
            nil
        }
    }

    /// The header runs from `CREATE` to the object keyword. Recognising it from the words allowed
    /// inside it rather than the words that end it means an unlisted word closes the header, which
    /// leaves a clause in place instead of taking one out of a statement body.
    private static let headerKeywords: Set<String> = [
        "CREATE", "OR", "REPLACE", "ALGORITHM", "UNDEFINED", "MERGE", "TEMPTABLE",
        "DEFINER", "SQL", "SECURITY", "INVOKER", "TEMPORARY", "AGGREGATE"
    ]

    private static func track(_ keyword: String, in state: inout ScanState) {
        if keyword == "CREATE" {
            state.isInCreateHeader = true
            return
        }
        if !headerKeywords.contains(keyword) {
            state.isInCreateHeader = false
        }
    }

    private static func track(_ character: Character, in state: inout ScanState) {
        if character == "(" {
            state.parenthesisDepth += 1
        } else if character == ")" {
            state.parenthesisDepth = max(0, state.parenthesisDepth - 1)
        } else if character == ";" {
            state.isInCreateHeader = false
        }
    }

    private static func assignedValueEnd(
        in characters: [Character],
        from start: Int,
        value: (_ characters: [Character], _ start: Int) -> Int?
    ) -> Int? {
        var index = skippingBlanks(in: characters, from: start)
        guard index < characters.count, characters[index] == "=" else { return nil }
        index = skippingBlanks(in: characters, from: index + 1)
        return value(characters, index)
    }

    private static func digitRunEnd(in characters: [Character], from start: Int) -> Int? {
        var index = start
        while index < characters.count, characters[index].isASCII, characters[index].isNumber {
            index += 1
        }
        return index > start ? index : nil
    }

    /// A DEFINER is `user@host`, where either half arrives quoted or bare, and `CURRENT_USER`
    /// stands alone without a host.
    private static func accountEnd(in characters: [Character], from start: Int) -> Int? {
        guard let userEnd = accountPartEnd(in: characters, from: start) else { return nil }
        let separator = skippingBlanks(in: characters, from: userEnd)
        guard separator < characters.count, characters[separator] == "@" else { return userEnd }
        let hostStart = skippingBlanks(in: characters, from: separator + 1)
        return accountPartEnd(in: characters, from: hostStart) ?? userEnd
    }

    private static func accountPartEnd(in characters: [Character], from start: Int) -> Int? {
        if let quoted = quotedRunEnd(in: characters, from: start) { return quoted }
        var index = start
        while index < characters.count, isAccountCharacter(characters[index]) {
            index += 1
        }
        return index > start ? index : nil
    }

    /// A removed clause leaves the separator that preceded it. Take the run of blanks that followed
    /// too, and where the clause ended its fragment, the one that preceded it as well.
    private static func closeGap(
        in characters: [Character],
        after clauseEnd: Int,
        output: inout [Character]
    ) -> Int {
        let precededByBlank = output.last.map(isBlank) ?? true
        guard precededByBlank else { return clauseEnd }

        let index = skippingBlanks(in: characters, from: clauseEnd)
        guard index >= characters.count || endsFragment(characters[index]) else { return index }
        while let last = output.last, isBlank(last) {
            output.removeLast()
        }
        return index
    }

    private static func quotedRunEnd(in characters: [Character], from start: Int) -> Int? {
        guard start < characters.count else { return nil }
        let delimiter = characters[start]
        guard delimiter == "'" || delimiter == "\"" || delimiter == "`" else { return nil }

        let escapesWithBackslash = delimiter != "`"
        var index = start + 1
        while index < characters.count {
            if escapesWithBackslash, characters[index] == "\\" {
                index += 2
                continue
            }
            guard characters[index] == delimiter else {
                index += 1
                continue
            }
            if index + 1 < characters.count, characters[index + 1] == delimiter {
                index += 2
                continue
            }
            return index + 1
        }
        return characters.count
    }

    /// Text inside a comment is copied rather than rewritten. Every dialect spells its comments
    /// differently enough that a wrong guess here only ever leaves a clause in place.
    private static func commentRunEnd(in characters: [Character], from start: Int) -> Int? {
        let next = start + 1 < characters.count ? characters[start + 1] : nil
        if characters[start] == "#" || (characters[start] == "-" && next == "-") {
            return lineEnd(in: characters, from: start)
        }
        guard characters[start] == "/", next == "*" else { return nil }
        var index = start + 2
        while index + 1 < characters.count {
            if characters[index] == "*", characters[index + 1] == "/" { return index + 2 }
            index += 1
        }
        return characters.count
    }

    private static func lineEnd(in characters: [Character], from start: Int) -> Int {
        var index = start
        while index < characters.count, characters[index] != "\n", characters[index] != "\r" {
            index += 1
        }
        return index
    }

    private static func skippingBlanks(in characters: [Character], from start: Int) -> Int {
        var index = start
        while index < characters.count, isBlank(characters[index]) {
            index += 1
        }
        return index
    }

    private static func isBlank(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    private static func endsFragment(_ character: Character) -> Bool {
        character == ";" || character == ")" || character == "\n" || character == "\r"
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }

    private static func isAccountCharacter(_ character: Character) -> Bool {
        isWordCharacter(character) || character == "." || character == "-" || character == "%"
    }
}
