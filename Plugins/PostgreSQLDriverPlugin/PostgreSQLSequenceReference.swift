//
//  PostgreSQLSequenceReference.swift
//  PostgreSQLDriverPlugin
//
//  A sequence a column default reads, in the two spellings a copy has to choose between. Pure, so
//  the rewrite of a deparsed default is pinned by a test without a server.
//

import Foundation
import TableProPluginKit

struct PostgreSQLSequenceReference: Equatable {
    /// `regclassout` under a `search_path` of `pg_catalog`: `sales.orders_id_seq`.
    let qualifiedName: String
    /// `regclassout` where the sequence's own schema is on the path: `orders_id_seq`.
    let relativeName: String

    /// Pairs the two arrays the column read projects, both ordered by the sequence's oid. Nil when
    /// either cannot be read or they disagree in length, because a pairing that is off by one would
    /// point a default at the wrong sequence.
    static func references(qualified: String?, relative: String?) -> [PostgreSQLSequenceReference]? {
        guard let qualifiedNames = names(qualified), let relativeNames = names(relative),
              qualifiedNames.count == relativeNames.count else { return nil }
        return zip(qualifiedNames, relativeNames).map {
            PostgreSQLSequenceReference(qualifiedName: $0, relativeName: $1)
        }
    }

    /// `standard_conforming_strings` as `current_setting` reports it. Nil for anything else, because
    /// the setting decides whether a backslash in a literal is doubled.
    static func standardConformingStrings(_ setting: String?) -> Bool? {
        switch setting?.lowercased() {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    /// The default with each listed sequence's literal written relative and every other name left
    /// qualified.
    ///
    /// A sequence the copy recreates is created beside the table under an unqualified name, so the
    /// default has to find it through the target's path. Everything else the default names, a
    /// function, a type or a sequence in another schema, is not recreated and has to keep its schema.
    ///
    /// Only a whole string literal cast to `regclass` whose value is a listed name is replaced.
    /// `ruleutils` writes a `regclass` constant as `'<regclassout>'::regclass`, quoted by the same
    /// `simple_quote_literal` as every other string it writes. The text is walked literal by literal
    /// and identifier by identifier, so a quoted identifier or a string constant that happens to hold
    /// the same characters is never touched. Nil when a listed sequence is never found, or the text
    /// does not lex: written as it stands, that default would still read the source's sequence.
    static func relativize(
        _ expression: String,
        references: [PostgreSQLSequenceReference],
        standardConformingStrings: Bool?
    ) -> String? {
        guard !references.isEmpty else { return expression }
        guard let standardConformingStrings else { return nil }
        let relativeByQualified = Dictionary(
            references.map { ($0.qualifiedName, $0.relativeName) },
            uniquingKeysWith: { first, _ in first }
        )
        var unmatched = Set(relativeByQualified.keys)
        let scalars = Array(expression.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            switch scalars[index] {
            case "\"":
                guard let end = identifierEnd(scalars, openingAt: index) else { return nil }
                output.append(contentsOf: scalars[index..<end])
                index = end
            case "'":
                guard let literal = stringLiteral(
                    scalars, openingAt: index, standardConformingStrings: standardConformingStrings
                ) else { return nil }
                if isRegclassCast(scalars, at: literal.end), let relative = relativeByQualified[literal.value] {
                    unmatched.remove(literal.value)
                    output.append(contentsOf: quotedLiteral(
                        relative, standardConformingStrings: standardConformingStrings
                    ).unicodeScalars)
                } else {
                    output.append(contentsOf: scalars[index..<literal.end])
                }
                index = literal.end
            default:
                output.append(scalars[index])
                index += 1
            }
        }
        return unmatched.isEmpty ? String(output) : nil
    }

    /// `simple_quote_literal` in `ruleutils.c`: a quote is always doubled, a backslash only when
    /// `standard_conforming_strings` is off, and never an `E` prefix. Scalar by scalar, as the server
    /// works byte by byte: a quote followed by a combining mark is one `Character` and still a quote.
    static func quotedLiteral(_ value: String, standardConformingStrings: Bool) -> String {
        let quote: Unicode.Scalar = "'"
        var literal = String.UnicodeScalarView([quote])
        for scalar in value.unicodeScalars {
            if scalar == quote || (scalar == "\\" && !standardConformingStrings) {
                literal.append(scalar)
            }
            literal.append(scalar)
        }
        literal.append(quote)
        return String(literal)
    }

    private static func names(_ array: String?) -> [String]? {
        guard let array else { return [] }
        guard let elements = PostgresArrayLiteralCodec.parse(array) else { return nil }
        var names: [String] = []
        for element in elements {
            guard case .value(let name) = element else { return nil }
            names.append(name)
        }
        return names
    }

    private static func identifierEnd(_ scalars: [Unicode.Scalar], openingAt start: Int) -> Int? {
        var index = start + 1
        while index < scalars.count {
            guard scalars[index] == "\"" else {
                index += 1
                continue
            }
            guard index + 1 < scalars.count, scalars[index + 1] == "\"" else { return index + 1 }
            index += 2
        }
        return nil
    }

    private static func stringLiteral(
        _ scalars: [Unicode.Scalar],
        openingAt start: Int,
        standardConformingStrings: Bool
    ) -> (value: String, end: Int)? {
        var value = String.UnicodeScalarView()
        var index = start + 1
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\", !standardConformingStrings {
                guard index + 1 < scalars.count else { return nil }
                value.append(scalars[index + 1])
                index += 2
                continue
            }
            guard scalar == "'" else {
                value.append(scalar)
                index += 1
                continue
            }
            guard index + 1 < scalars.count, scalars[index + 1] == "'" else {
                return (String(value), index + 1)
            }
            value.append(scalar)
            index += 2
        }
        return nil
    }

    private static let regclassCast = Array("::regclass".unicodeScalars)

    private static func isRegclassCast(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        let end = index + regclassCast.count
        guard end <= scalars.count, Array(scalars[index..<end]) == regclassCast else { return false }
        guard end < scalars.count else { return true }
        let next = scalars[end]
        let continuesName = next.properties.isAlphabetic || next.properties.numericType != nil
            || next == "_" || next == "$"
        return !continuesName && next != "["
    }
}
