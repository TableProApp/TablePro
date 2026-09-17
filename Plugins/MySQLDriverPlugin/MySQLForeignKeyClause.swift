//
//  MySQLForeignKeyClause.swift
//  MySQLDriverPlugin
//
//  The foreign keys a `SHOW CREATE TABLE` statement carries, for a database whose
//  `information_schema` does not describe it.
//

import Foundation
import TableProPluginKit

internal enum MySQLForeignKeyClause {
    /// One `PluginForeignKeyInfo` per column, which is the shape the catalog read produces.
    ///
    /// `database` fills `referencedSchema` for an unqualified clause, because the catalog names the
    /// referenced database on every row and a caller comparing the two would otherwise read a
    /// same-database key as having moved.
    ///
    /// `omittedAction` is what the server's own `REFERENTIAL_CONSTRAINTS` would have said for a
    /// clause that names no action. That spelling is a version fact, not a constant, so it comes
    /// from `MySQLServerVersion.omittedForeignKeyAction(banner:flavor:)`.
    ///
    /// A key with no name at all is dropped rather than carried with an empty one: no server
    /// measured emits one, and a nameless key reaches a schema comparison as `DROP FOREIGN KEY`
    /// with nothing to name.
    static func parse(createTable sql: String, database: String, omittedAction: String) -> [PluginForeignKeyInfo] {
        let text = Substring(sql)
        guard let body = MySQLCreateTableScanner.firstGroup(in: text) else { return [] }
        let quote = quoteCharacter(inHeaderOf: text, endingAt: body.startIndex)
        return MySQLCreateTableScanner.topLevelElements(of: body).flatMap { element in
            foreignKey(in: element, database: database, quote: quote, omittedAction: omittedAction)
        }
    }

    /// `SHOW CREATE TABLE` renders every identifier with the session's quote character, so the
    /// table's own name in the header says which one to read the clauses with. Under `ANSI_QUOTES`
    /// that is a double quote.
    private static func quoteCharacter(inHeaderOf text: Substring, endingAt end: Substring.Index) -> Character {
        for character in text[text.startIndex ..< end] where character == "`" || character == "\"" {
            return character
        }
        return "`"
    }

    private static func foreignKey(
        in element: Substring,
        database: String,
        quote: Character,
        omittedAction: String
    ) -> [PluginForeignKeyInfo] {
        var rest = element
        var name: String?
        if MySQLCreateTableScanner.consume("CONSTRAINT", from: &rest) {
            guard let declared = MySQLCreateTableScanner.consumeQuotedName(from: &rest, quote: quote) else { return [] }
            name = declared
        }
        guard MySQLCreateTableScanner.consume("FOREIGN", from: &rest),
              MySQLCreateTableScanner.consume("KEY", from: &rest)
        else { return [] }

        /// `FOREIGN KEY [index_name] (…)`: the optional index name stands in for the constraint
        /// name where the clause declares no `CONSTRAINT`.
        if let indexName = MySQLCreateTableScanner.consumeQuotedName(from: &rest, quote: quote) {
            name = name ?? indexName
        }
        guard let name,
              let columns = consumeNameList(from: &rest, quote: quote),
              MySQLCreateTableScanner.consume("REFERENCES", from: &rest),
              let referenced = consumeQualifiedName(from: &rest, quote: quote),
              let referencedColumns = consumeNameList(from: &rest, quote: quote)
        else { return [] }

        let tail = rest.uppercased()
        let onDelete = action(after: "ON DELETE", in: tail) ?? omittedAction
        let onUpdate = action(after: "ON UPDATE", in: tail) ?? omittedAction

        return zip(columns, referencedColumns).map { column, referencedColumn in
            PluginForeignKeyInfo(
                name: name,
                column: column,
                referencedTable: referenced.name,
                referencedColumn: referencedColumn,
                referencedSchema: referenced.schema ?? database.nilIfEmpty,
                onDelete: onDelete,
                onUpdate: onUpdate
            )
        }
    }

    /// A parenthesised list of quoted names, consumed whole so the text after it is the action tail.
    private static func consumeNameList(from rest: inout Substring, quote: Character) -> [String]? {
        let text = rest.drop(while: \.isWhitespace)
        guard text.first == "(", let body = MySQLCreateTableScanner.firstGroup(in: text) else { return nil }
        var names: [String] = []
        for element in MySQLCreateTableScanner.topLevelElements(of: body) {
            var piece = element
            guard let name = MySQLCreateTableScanner.consumeQuotedName(from: &piece, quote: quote) else { return nil }
            names.append(name)
        }
        guard !names.isEmpty else { return nil }
        rest = text[text.index(after: body.endIndex)...]
        return names
    }

    private static func consumeQualifiedName(
        from rest: inout Substring,
        quote: Character
    ) -> (schema: String?, name: String)? {
        guard let first = MySQLCreateTableScanner.consumeQuotedName(from: &rest, quote: quote) else { return nil }
        let afterDot = rest.drop(while: \.isWhitespace)
        guard afterDot.first == "." else { return (nil, first) }
        var qualified = afterDot.dropFirst()
        guard let second = MySQLCreateTableScanner.consumeQuotedName(from: &qualified, quote: quote) else {
            return (nil, first)
        }
        rest = qualified
        return (first, second)
    }

    private static let referentialActions = ["CASCADE", "SET NULL", "SET DEFAULT", "NO ACTION", "RESTRICT"]

    private static func action(after keyword: String, in tail: String) -> String? {
        guard let clause = tail.range(of: keyword) else { return nil }
        let named = tail[clause.upperBound...].drop(while: \.isWhitespace)
        return referentialActions.first { named.hasPrefix($0) }
    }
}
