//
//  MySQLViewRowEditing.swift
//  MySQLDriverPlugin
//
//  Works out whether the grid may write rows through a MySQL or MariaDB view. The server answers
//  whether the view is updatable; the definition it stores names every column fully qualified,
//  as in "select `db`.`t`.`id` AS `key_id` from `db`.`t`", which says which base column each view
//  column shows. Pure, so it is testable without a server.
//

import Foundation
import TableProPluginKit

enum MySQLViewRowEditing {
    struct BaseTable: Equatable {
        let database: String?
        let name: String
    }

    struct Definition: Equatable {
        /// Nil when the FROM clause is anything but one table: a join, a list or a derived table.
        let baseTable: BaseTable?
        let origins: [PluginViewColumnOrigin]
    }

    static func viewQuery(name: String, database: String?, escape: (String) -> String) -> String {
        """
        SELECT IS_UPDATABLE, VIEW_DEFINITION FROM information_schema.VIEWS \
        WHERE TABLE_SCHEMA = \(schemaExpression(database, escape: escape)) AND TABLE_NAME = '\(escape(name))'
        """
    }

    static func primaryKeyQuery(table: BaseTable, viewDatabase: String?, escape: (String) -> String) -> String {
        """
        SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE \
        WHERE TABLE_SCHEMA = \(schemaExpression(table.database ?? viewDatabase, escape: escape)) \
        AND TABLE_NAME = '\(escape(table.name))' AND CONSTRAINT_NAME = 'PRIMARY' \
        ORDER BY ORDINAL_POSITION
        """
    }

    private static func schemaExpression(_ database: String?, escape: (String) -> String) -> String {
        database.map { "'\(escape($0))'" } ?? "DATABASE()"
    }

    /// A nil definition is one the server withheld or that is not a SELECT.
    static func resolve(isUpdatable: Bool, definition: Definition?, baseKeyColumns: [String]) -> PluginViewRowEditing {
        guard let definition else { return .readOnly(.notUpdatable) }
        return PluginViewRowEditing.resolve(
            isUpdatable: isUpdatable,
            baseTableCount: definition.baseTable == nil ? 2 : 1,
            baseKeyColumns: baseKeyColumns,
            origins: definition.origins
        )
    }

    static func parse(definition text: String) -> Definition? {
        let tokens = Token.tokenize(text)
        guard let first = tokens.first, first.isWord("select") else { return nil }
        let fromIndex = tokens.firstIndex { $0.depth == 0 && $0.isWord("from") } ?? tokens.endIndex
        let baseTable = singleTable(in: Array(tokens[fromIndex...].dropFirst()))
        let alias = baseTable?.alias

        var origins: [PluginViewColumnOrigin] = []
        for item in split(Array(tokens[1..<fromIndex]), separator: ",") {
            guard item.count >= 3,
                  item[item.count - 2].isWord("as"),
                  let viewColumn = item.last?.identifier,
                  let reference = columnReference(Array(item.dropLast(2))),
                  let table = baseTable?.table
            else { continue }
            let qualifier = reference.qualifier
            let matches: Bool
            switch qualifier.count {
            case 2: matches = alias == nil && qualifier[0] == table.database && qualifier[1] == table.name
            case 1: matches = qualifier[0] == (alias ?? table.name)
            default: matches = alias == nil
            }
            if matches {
                origins.append(PluginViewColumnOrigin(viewColumn: viewColumn, baseColumn: reference.column))
            }
        }
        return Definition(baseTable: baseTable?.table, origins: origins)
    }

    private static let clauseKeywords: Set<String> = [
        "where", "group", "having", "order", "limit", "window", "union", "for", "lock", "into",
    ]

    private static func singleTable(in tokens: [Token]) -> (table: BaseTable, alias: String?)? {
        let clause = Array(tokens.prefix { !($0.depth == 0 && clauseKeywords.contains($0.text.lowercased())) })
        var parts: [String] = []
        var index = 0
        while index < clause.count, let name = clause[index].identifier {
            parts.append(name)
            guard index + 1 < clause.count, clause[index + 1].text == "." else {
                index += 1
                break
            }
            index += 2
        }
        let rest = clause[index...]
        guard (1...2).contains(parts.count), rest.count <= 1 else { return nil }
        let alias: String?
        if let aliasToken = rest.first {
            guard let name = aliasToken.identifier else { return nil }
            alias = name
        } else {
            alias = nil
        }
        let table = parts.count == 2
            ? BaseTable(database: parts[0], name: parts[1])
            : BaseTable(database: nil, name: parts[0])
        return (table, alias)
    }

    private static func columnReference(_ tokens: [Token]) -> (qualifier: [String], column: String)? {
        guard tokens.count % 2 == 1, tokens.count <= 5 else { return nil }
        var names: [String] = []
        for (offset, token) in tokens.enumerated() {
            if offset % 2 == 1 {
                guard token.text == "." else { return nil }
            } else {
                guard let name = token.identifier else { return nil }
                names.append(name)
            }
        }
        guard let column = names.popLast() else { return nil }
        return (names, column)
    }

    private static func split(_ tokens: [Token], separator: String) -> [[Token]] {
        var items: [[Token]] = [[]]
        for token in tokens {
            if token.depth == 0, token.text == separator, !token.isQuoted {
                items.append([])
            } else {
                items[items.count - 1].append(token)
            }
        }
        return items.filter { !$0.isEmpty }
    }
}

private struct Token {
    let text: String
    let depth: Int
    let isQuoted: Bool

    var identifier: String? {
        if isQuoted { return text }
        guard let first = text.unicodeScalars.first,
              CharacterSet.letters.contains(first) || first == "_" else { return nil }
        return text
    }

    func isWord(_ word: String) -> Bool {
        !isQuoted && text.caseInsensitiveCompare(word) == .orderedSame
    }

    /// Backquoted identifiers are kept as identifiers with their doubled backquotes undone. A
    /// string literal becomes one opaque token, so a comma or keyword inside it never counts.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var depth = 0
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            switch character {
            case "`":
                var name = ""
                index += 1
                while index < characters.count {
                    if characters[index] == "`" {
                        if index + 1 < characters.count, characters[index + 1] == "`" {
                            name.append("`")
                            index += 2
                            continue
                        }
                        break
                    }
                    name.append(characters[index])
                    index += 1
                }
                tokens.append(Token(text: name, depth: depth, isQuoted: true))
                index += 1
            case "'", "\"":
                index += 1
                while index < characters.count {
                    if characters[index] == "\\" {
                        index += 2
                        continue
                    }
                    if characters[index] == character {
                        if index + 1 < characters.count, characters[index + 1] == character {
                            index += 2
                            continue
                        }
                        break
                    }
                    index += 1
                }
                tokens.append(Token(text: "''", depth: depth, isQuoted: false))
                index += 1
            case "(":
                tokens.append(Token(text: "(", depth: depth, isQuoted: false))
                depth += 1
                index += 1
            case ")":
                depth -= 1
                tokens.append(Token(text: ")", depth: depth, isQuoted: false))
                index += 1
            case _ where character.isWhitespace:
                index += 1
            case _ where character.isLetter || character.isNumber || character == "_" || character == "$":
                var word = ""
                while index < characters.count,
                      characters[index].isLetter || characters[index].isNumber
                      || characters[index] == "_" || characters[index] == "$" {
                    word.append(characters[index])
                    index += 1
                }
                tokens.append(Token(text: word, depth: depth, isQuoted: false))
            default:
                tokens.append(Token(text: String(character), depth: depth, isQuoted: false))
                index += 1
            }
        }
        return tokens
    }
}
