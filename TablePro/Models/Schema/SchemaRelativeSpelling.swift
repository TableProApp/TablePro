//
//  SchemaRelativeSpelling.swift
//  TablePro
//

import Foundation

/// A qualified catalog name said the way another schema resolves it.
///
/// A name the source qualified with its own schema means "the one beside this table", and on the
/// target that is the target's schema. Dropping the qualifier is what says so, and it is safe to do
/// on a name and on nothing else: a default or a generation expression is SQL text whose qualifiers
/// cannot be reached without parsing the expression, which is why those carry no rewritten spelling
/// at all.
internal enum SchemaRelativeSpelling {
    internal static func of(_ qualified: String, ownSchema: String?) -> String {
        guard let ownSchema, !ownSchema.isEmpty else { return qualified }
        guard let split = splitQualifier(qualified), split.schema == ownSchema else { return qualified }
        return split.rest
    }

    /// The type name with any schema off it, which is what two schemas of one database and two
    /// servers that installed an extension in different schemas have in common.
    ///
    /// Only a qualifier before the type's own parameters is one: `numeric(10,2)` has no schema, and
    /// the separator inside `geometry(Point,4326)` belongs to the parameter list.
    internal static func unqualified(_ type: String) -> String {
        let head = type.prefix { $0 != "(" && $0 != "[" }
        guard let split = splitQualifier(String(head)) else { return type }
        return split.rest + type.dropFirst(head.count)
    }

    private static func splitQualifier(_ qualified: String) -> (schema: String, rest: String)? {
        var characters = Array(qualified)
        guard let first = characters.first else { return nil }
        guard first == quote else { return splitBareQualifier(characters) }

        var schema = ""
        var index = 1
        while index < characters.count {
            let character = characters[index]
            if character == quote {
                guard index + 1 < characters.count, characters[index + 1] == quote else { break }
                schema.append(quote)
                index += 2
                continue
            }
            schema.append(character)
            index += 1
        }
        guard index + 1 < characters.count, characters[index] == quote, characters[index + 1] == separator else {
            return nil
        }
        characters.removeFirst(index + 2)
        return (schema, String(characters))
    }

    private static func splitBareQualifier(_ characters: [Character]) -> (schema: String, rest: String)? {
        guard let separatorIndex = characters.firstIndex(of: separator) else { return nil }
        let schema = String(characters[..<separatorIndex])
        guard !schema.isEmpty, !schema.contains(quote) else { return nil }
        return (schema, String(characters[characters.index(after: separatorIndex)...]))
    }

    private static let quote: Character = "\""
    private static let separator: Character = "."
}
