//
//  JSONRowNodeBuilder.swift
//  TablePro
//
//  Turns one result row into the JSON inspector's node tree.
//

import Foundation
import TableProPluginKit

enum JSONRowNodeBuilder {
    /// Root node for a row. `foreignKeys` is keyed by column name, the shape
    /// `TableRows.columnForeignKeys` already holds.
    static func build(
        path: JSONNodePath = .root,
        key: JSONNodeKey = .root,
        columns: [String],
        values: [PluginCellValue],
        columnTypes: [ColumnType],
        foreignKeys: [String: JSONForeignKeyRef]
    ) -> JSONRowNode {
        var children: [JSONRowNode] = []
        children.reserveCapacity(columns.count)

        for (index, column) in columns.enumerated() {
            let value = index < values.count ? values[index] : .null
            let type = index < columnTypes.count ? columnTypes[index] : nil
            /// The column's position leads its path component, because a result set's labels are not
            /// unique: an unaliased join selecting two `id` columns gives two of them. Sharing a path
            /// gives the two nodes one id in the `ForEach` that draws them, and one entry in the
            /// expanded set and the fetched-key map, so neither could be opened on its own.
            let childPath = path.appending("\(index).\(column)")
            children.append(
                JSONRowNode(
                    path: childPath,
                    key: .name(column),
                    value: nodeValue(
                        for: value,
                        type: type,
                        foreignKey: foreignKeys[column],
                        path: childPath
                    )
                )
            )
        }

        return JSONRowNode(path: path, key: key, value: .object(children))
    }

    private static func nodeValue(
        for value: PluginCellValue,
        type: ColumnType?,
        foreignKey: JSONForeignKeyRef?,
        path: JSONNodePath
    ) -> JSONNodeValue {
        switch value {
        case .null:
            guard let foreignKey else { return .scalar(.null) }
            return .foreignKey(foreignKey, .null)
        case .bytes(let data):
            return .scalar(.binary(data))
        case .text(let text):
            if let foreignKey {
                return .foreignKey(foreignKey, scalar(for: text, type: type))
            }
            if let document = parsedDocument(text, type: type) {
                return documentValue(document, path: path)
            }
            return .scalar(scalar(for: text, type: type))
        }
    }

    /// The scan cap the cell viewer already applies. A column holding a megabyte of JSON is not a
    /// tree anyone reads, and the inspector shows the text instead.
    static let maxScannedDocumentLength = 100_000

    /// A JSON column is parsed whatever it holds; any other column only when its text is shaped
    /// like a document, which is what makes a `TEXT` column holding JSON expand too.
    ///
    /// The parse is `JsonSyntaxParser`, the same one the JSON cell viewer reads with, so a document
    /// cannot render one way in a cell and another in the row.
    ///
    /// A top-level scalar is kept rather than dropped. `42`, `true`, `null` and `"text"` are all
    /// valid JSON documents, and a declared JSON column is allowed to hold one; handing them back
    /// to the column-type path printed the number as a string and the string with its own quotes
    /// still on. The gate below means only a JSON column ever reaches that case: any other column
    /// has to start with a brace or a bracket to be parsed at all.
    ///
    /// A scalar has to be strictly valid before it is retyped, because `JsonSyntaxParser` is a
    /// syntax highlighter's parser and not a validator: it drops the backslash from an unknown
    /// escape and reads `01` as a number. A column the engine never validated can hold either, and
    /// retyping one there would show the reader something the cell does not say. A container keeps
    /// the lenient parse it has always had, since its braces are what the tree is built from.
    private static func parsedDocument(_ text: String, type: ColumnType?) -> JsonSyntaxNode? {
        guard (text as NSString).length <= maxScannedDocumentLength else { return nil }
        if type?.isJsonType != true, !looksLikeDocument(text) { return nil }
        guard let parsed = JsonSyntaxParser.parse(text) else { return nil }
        switch parsed {
        case .object, .array: return parsed
        case .string, .number, .literal: return isStrictJSON(text) ? parsed : nil
        }
    }

    private static func isStrictJSON(_ text: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil
    }

    /// A cell holding `42` is a number column, not a JSON document, and treating it as one would
    /// nest every integer a level deeper than it belongs.
    static func looksLikeDocument(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace && !$0.isNewline }) else { return false }
        return first == "{" || first == "["
    }

    private static func documentValue(_ document: JsonSyntaxNode, path: JSONNodePath) -> JSONNodeValue {
        switch document {
        case .object(let members):
            let children = members.enumerated().map { index, member in
                let key = JsonSyntaxParser.decodeStringLiteral(member.key)
                let childPath = path.appending("\(index).\(key)")
                return JSONRowNode(
                    path: childPath,
                    key: .name(key),
                    value: documentValue(member.value, path: childPath)
                )
            }
            return .object(children)
        case .array(let elements):
            let children = elements.enumerated().map { index, element in
                let childPath = path.appending("[\(index)]")
                return JSONRowNode(
                    path: childPath,
                    key: .index(index),
                    value: documentValue(element, path: childPath)
                )
            }
            return .array(children)
        case .string(let raw):
            return .scalar(.string(JsonSyntaxParser.decodeStringLiteral(raw)))
        case .number(let literal):
            return .scalar(.number(literal))
        case .literal(let literal):
            switch literal {
            case "true": return .scalar(.bool(true))
            case "false": return .scalar(.bool(false))
            default: return .scalar(.null)
            }
        }
    }

    /// The column's own type decides whether a value is quoted, so a `DECIMAL` arriving as `"4.99"`
    /// stays a string the way the grid shows it and an `INT` arriving as `"2"` renders bare.
    static func scalar(for text: String, type: ColumnType?) -> JSONScalar {
        guard let type else { return .string(text) }
        switch type {
        case .integer, .decimal:
            guard let literal = JsonNumberNormalizer.numberLiteral(from: text) else { return .string(text) }
            return .number(literal)
        case .boolean:
            switch PluginSQLLiteral.booleanSynonym(for: text) {
            case .isTrue: return .bool(true)
            case .isFalse: return .bool(false)
            default: return .string(text)
            }
        case .text, .date, .timestamp, .datetime, .blob, .json, .enumType, .set, .spatial, .array:
            return .string(text)
        }
    }
}
