//
//  TableDDLComposer.swift
//  TablePro
//

import Foundation

/// Joins a table's `CREATE TABLE` to the statements that stand outside it.
///
/// A driver answers `fetchTableDDL` with the table alone and `fetchIndexDDL` with the indexes that
/// statement does not declare, because a dump replays them in different phases: the table before
/// its rows, the indexes after. Anything showing one table's whole definition at once, Copy DDL and
/// the MCP schema tools among them, puts the two back together here rather than each spelling out
/// its own separator.
internal enum TableDDLComposer {
    internal static func compose(tableDDL: String, indexDDL: [String], preamble: String = "") -> String {
        let statements = indexDDL
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix(";") ? $0 : "\($0);" }

        var composed = preamble.isEmpty ? tableDDL : "\(preamble)\n\(tableDDL)"
        guard !statements.isEmpty else { return composed }
        if !composed.hasSuffix(";") {
            composed += ";"
        }
        return composed + "\n\n" + statements.joined(separator: "\n")
    }

    /// One object's whole definition, read on a driver already pinned to its scope. The Structure
    /// tab's DDL, Show DDL and Copy DDL all come through here, so the three can never disagree about
    /// the same object. `includesDependencies` adds the sequences and enum types the table's columns
    /// use, which the Structure tab writes first so its text runs on its own.
    internal static func fetchDDL(
        for table: String,
        using driver: DatabaseDriver,
        includesDependencies: Bool
    ) async throws -> String {
        let preamble = includesDependencies ? try await dependencyPreamble(for: table, using: driver) : ""
        let baseDDL = try await driver.fetchTableDDL(table: table)
        let indexDDL = (try? await driver.fetchIndexDDL(table: table)) ?? []
        return compose(tableDDL: baseDDL, indexDDL: indexDDL, preamble: preamble)
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
