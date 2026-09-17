//
//  TableDDLComposer.swift
//  TablePro
//

import Foundation

/// Joins a table's `CREATE TABLE` to the statements that stand outside it.
///
/// A driver answers `fetchTableDDL` with the table alone, `fetchCommentDDL` with its comments and
/// `fetchIndexDDL` with the indexes that statement does not declare, because a dump replays them in
/// different phases: the table and its comments before its rows, the indexes after. Anything showing
/// one table's whole definition at once, Copy DDL and the MCP schema tools among them, puts the
/// pieces back together here rather than each spelling out its own separator.
internal enum TableDDLComposer {
    /// The comments keep the dump's own placement, between the table and its indexes, so the text
    /// Show DDL and Copy DDL hand over is the text a restore runs.
    internal static func compose(
        tableDDL: String,
        indexDDL: [String],
        commentDDL: [String] = [],
        preamble: String = ""
    ) -> String {
        let comments = terminated(commentDDL)
        let indexes = terminated(indexDDL)

        var composed = preamble.isEmpty ? tableDDL : "\(preamble)\n\(tableDDL)"
        guard !comments.isEmpty || !indexes.isEmpty else { return composed }
        if !composed.hasSuffix(";") {
            composed += ";"
        }
        for block in [comments, indexes] where !block.isEmpty {
            composed += "\n\n" + block.joined(separator: "\n")
        }
        return composed
    }

    private static func terminated(_ statements: [String]) -> [String] {
        statements
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix(";") ? $0 : "\($0);" }
    }

    /// One object's whole definition, read on a driver already pinned to its scope. The Structure
    /// tab's DDL, Show DDL and Copy DDL all come through here, so the three can never disagree about
    /// the same object. `includesDependencies` adds the sequences and enum types the table's columns
    /// use, which the Structure tab writes first so its text runs on its own.
    /// `schema` names the container the caller means, for the callers that know it. All three reads
    /// take it together: a DDL composed from one container's CREATE TABLE and another's indexes and
    /// comments describes a table that does not exist.
    internal static func fetchDDL(
        for table: String,
        using driver: DatabaseDriver,
        includesDependencies: Bool,
        schema: String? = nil
    ) async throws -> String {
        let preamble = includesDependencies ? try await dependencyPreamble(for: table, using: driver) : ""
        let baseDDL = try await driver.fetchTableDDL(table: table, schema: schema)
        let indexDDL = (try? await driver.fetchIndexDDL(table: table, schema: schema)) ?? []
        let commentDDL = (try? await driver.fetchCommentDDL(table: table, schema: schema)) ?? []
        return compose(
            tableDDL: baseDDL,
            indexDDL: indexDDL,
            commentDDL: commentDDL,
            preamble: preamble
        )
    }

    private static func dependencyPreamble(for table: String, using driver: DatabaseDriver) async throws -> String {
        let sequences = try await driver.fetchDependentSequences(forTable: table)
        let enumTypes = try await driver.fetchDependentTypes(forTable: table)
        var preamble = ""
        for sequence in sequences {
            preamble += sequence.ddl + "\n\n"
        }
        for enumType in enumTypes {
            let quotedName = "\"\(enumType.name.replacingOccurrences(of: "\"", with: "\"\""))\""
            let quotedLabels = enumType.labels.map { "'\(SQLEscaping.escapeStringLiteral($0))'" }
            preamble += "CREATE TYPE \(quotedName) AS ENUM (\(quotedLabels.joined(separator: ", ")));\n"
        }
        return preamble
    }
}
