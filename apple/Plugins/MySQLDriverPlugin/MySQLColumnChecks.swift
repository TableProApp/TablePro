//
//  MySQLColumnChecks.swift
//  MySQLDriverPlugin
//
//  MariaDB's CHECK written on a column: where it is read from, which column owns it, and how a
//  MODIFY restates it.
//

import Foundation
import os
import TableProMySQLCore
import TableProPluginKit

/// MariaDB lists a column's own CHECK in `CHECK_CONSTRAINTS` with `LEVEL = 'Column'` and drops it on any
/// `MODIFY` that does not restate it. Measured on 11.4: the constraint keeps the name the column had when
/// the check was written through a rename, while the clause follows the rename, so the owner is the
/// column whose `SHOW CREATE TABLE` line ends with the clause. A `CHANGE` that restates the clause with
/// the new name keeps exactly one check.
internal enum MySQLColumnChecks {
    static func clausesQuery(schema: String, table: String) -> String {
        """
        SELECT CHECK_CLAUSE
        FROM INFORMATION_SCHEMA.CHECK_CONSTRAINTS
        WHERE CONSTRAINT_SCHEMA = '\(mysqlEscapeStringLiteral(schema))'
            AND TABLE_NAME = '\(mysqlEscapeStringLiteral(table))'
            AND LEVEL = 'Column'
        """
    }

    /// A name as the server prints it in `SHOW CREATE TABLE` and in a clause: backticked, or in double
    /// quotes under `ANSI_QUOTES`.
    static func printedNames(_ name: String) -> [String] {
        identifierQuotes.map { quoted(name, with: $0) }
    }

    /// Each clause given to the column whose line ends with ` CHECK (<clause>)`. A clause no line ends with
    /// stays unplaced, and its column is left with none.
    static func place(clauses: [String], columns: [String], createTable: String) -> [String: String] {
        var unplaced = clauses
        var placed: [String: String] = [:]
        for column in columns {
            guard let line = columnLine(column, in: createTable),
                  let index = unplaced.firstIndex(where: { line.hasSuffix(" CHECK (\($0))") })
            else { continue }
            placed[column] = unplaced.remove(at: index)
        }
        return placed
    }

    /// The clause as a `CHANGE` restates it: only a quoted identifier is renamed, never a literal such as a JSON path.
    static func restated(_ clause: String?, renaming oldName: String, to newName: String) -> String? {
        guard let clause = clause?.nilIfEmpty else { return nil }
        guard oldName != newName else { return clause }
        let scalars = Array(clause.unicodeScalars)
        var text = String.UnicodeScalarView()
        var copied = 0
        for identifier in quotedIdentifiers(in: scalars) where namesColumn(identifier.name, oldName) {
            text.append(contentsOf: scalars[copied..<identifier.range.lowerBound])
            text.append(contentsOf: quoted(newName, with: identifier.quote).unicodeScalars)
            copied = identifier.range.upperBound
        }
        text.append(contentsOf: scalars[copied...])
        return String(text)
    }

    /// The app writes one `ALTER` per column change, and a rename rewrites every clause naming the column,
    /// so a restated clause still holding another renamed column's old name fails with ERROR 1054 once
    /// that rename has run.
    static func renameRefusal(operations: [PluginSchemaOperation]) -> String? {
        let modifications = operations.compactMap { operation -> (old: PluginColumnDefinition, new: PluginColumnDefinition)? in
            guard case .modifyColumn(let old, let new) = operation else { return nil }
            return (old, new)
        }
        let renamed = modifications.filter { $0.old.name != $0.new.name }.map { $0.old.name }
        for modification in modifications {
            guard let clause = restated(
                modification.new.columnCheck, renaming: modification.old.name, to: modification.new.name
            ) else { continue }
            let identifiers = quotedIdentifiers(in: Array(clause.unicodeScalars)).map(\.name)
            let named = renamed.first { name in
                name != modification.old.name && identifiers.contains { namesColumn($0, name) }
            }
            guard let named else { continue }
            return String(
                format: String(
                    localized: "The CHECK on column %@ names column %@, which this save renames. Save the rename on its own first."
                ),
                modification.new.name,
                named
            )
        }
        return nil
    }

    private static let identifierQuotes: [Unicode.Scalar] = ["`", "\""]

    private struct QuotedIdentifier {
        let quote: Unicode.Scalar
        let name: String
        let range: Range<Int>
    }

    /// Column names compare without regard to case on MariaDB.
    private static func namesColumn(_ identifier: String, _ column: String) -> Bool {
        identifier.caseInsensitiveCompare(column) == .orderedSame
    }

    private static func quoted(_ name: String, with quote: Unicode.Scalar) -> String {
        var text = String.UnicodeScalarView([quote])
        for scalar in name.unicodeScalars {
            text.append(scalar)
            if scalar == quote { text.append(quote) }
        }
        text.append(quote)
        return String(text)
    }

    /// Scalars, not Characters: a combining mark after a quote would hide it inside one grapheme.
    private static func quotedIdentifiers(in scalars: [Unicode.Scalar]) -> [QuotedIdentifier] {
        var found: [QuotedIdentifier] = []
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "'" {
                index = endOfStringLiteral(in: scalars, openingAt: index)
            } else if identifierQuotes.contains(scalar) {
                guard let identifier = quotedIdentifier(in: scalars, openingAt: index) else { break }
                found.append(identifier)
                index = identifier.range.upperBound
            } else {
                index += 1
            }
        }
        return found
    }

    /// MariaDB prints a literal in single quotes, escaping a quote inside it as `''` or `\'`.
    private static func endOfStringLiteral(in scalars: [Unicode.Scalar], openingAt start: Int) -> Int {
        var index = start + 1
        while index < scalars.count {
            switch scalars[index] {
            case "\\":
                index += 2
            case "'":
                guard index + 1 < scalars.count, scalars[index + 1] == "'" else { return index + 1 }
                index += 2
            default:
                index += 1
            }
        }
        return scalars.count
    }

    /// Nil for an identifier the clause never closes, which leaves the rest of it as read.
    private static func quotedIdentifier(in scalars: [Unicode.Scalar], openingAt start: Int) -> QuotedIdentifier? {
        let quote = scalars[start]
        var name = String.UnicodeScalarView()
        var index = start + 1
        while index < scalars.count {
            guard scalars[index] == quote else {
                name.append(scalars[index])
                index += 1
                continue
            }
            guard index + 1 < scalars.count, scalars[index + 1] == quote else {
                return QuotedIdentifier(quote: quote, name: String(name), range: start..<(index + 1))
            }
            name.append(quote)
            index += 2
        }
        return nil
    }

    /// `SHOW CREATE TABLE` prints each column on a line of its own, two spaces in, with line breaks inside
    /// strings escaped.
    private static func columnLine(_ column: String, in createTable: String) -> Substring? {
        for printed in printedNames(column) {
            guard let head = createTable.range(of: "\n  \(printed) ") else { continue }
            let line = createTable[head.lowerBound...].dropFirst(3).prefix { $0 != "\n" }
            return line.hasSuffix(",") ? line.dropLast() : line
        }
        return nil
    }
}

internal extension MySQLPluginDriver {
    func reviewSchemaChange(
        table: String,
        schema: String?,
        operations: [PluginSchemaOperation]
    ) async throws -> PluginSchemaChangeReview {
        guard flavor.isMariaDB else { return PluginSchemaChangeReview() }
        return PluginSchemaChangeReview(refusal: MySQLColumnChecks.renameRefusal(operations: operations))
    }

    /// Each column's own check, by column name. Empty off MariaDB, before its catalog has `LEVEL`, and when
    /// the catalog refuses: the columns then read as they did before checks were read at all.
    func mariadbColumnChecks(table: String, schema: String?, columns: [String]) async throws -> [String: String] {
        let identity = serverIdentity
        guard identity.flavor.isMariaDB,
              MySQLCheckConstraints.source(banner: identity.banner, flavor: identity.flavor) == .informationSchema,
              catalogVisibility.visibility(of: effectiveSchema(schema)) != .blind,
              try await catalogHasColumn(.checkConstraintLevel),
              await !resolvesToTemporaryTable(table, schema: schema)
        else { return [:] }
        do {
            let result = try await execute(
                ownStatement: MySQLColumnChecks.clausesQuery(schema: effectiveSchema(schema), table: table)
            )
            let clauses = result.rows.compactMap { $0[safe: 0]?.asText }
            guard !clauses.isEmpty else { return [:] }
            let ddl = try await execute(query: "SHOW CREATE TABLE \(qualifiedName(table, schema: schema))")
            guard let createTable = ddl.rows.first?[safe: 1]?.asText else { return [:] }
            return MySQLColumnChecks.place(clauses: clauses, columns: columns, createTable: createTable)
        } catch let error as MariaDBPluginError
            where MySQLCatalogVisibilityRule.settlesBlindness(code: error.code) {
            Self.logger.warning(
                "column check read refused code=\(error.code, privacy: .public) message=\(error.message)"
            )
            return [:]
        }
    }
}

internal extension PluginColumnInfo {
    func withColumnCheck(_ columnCheck: String?) -> PluginColumnInfo {
        PluginColumnInfo(
            name: name,
            dataType: dataType,
            isNullable: isNullable,
            isPrimaryKey: isPrimaryKey,
            defaultValue: defaultValue,
            extra: extra,
            charset: charset,
            collation: collation,
            comment: comment,
            identityKind: identityKind,
            isGenerated: isGenerated,
            allowedValues: allowedValues,
            generationExpression: generationExpression,
            generationKind: generationKind,
            ddlSpelling: ddlSpelling,
            ddlDefault: ddlDefault,
            ddlGenerationExpression: ddlGenerationExpression,
            ddlCollation: ddlCollation,
            classificationTypeName: classificationTypeName,
            columnCheck: columnCheck
        )
    }
}
