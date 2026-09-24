//
//  QueryContextRenderer.swift
//  TablePro
//

import Foundation

enum QueryContextRenderer {
    static let characterBudget = 40_000

    struct Rendering: Equatable {
        let text: String
        let sentTables: [QueryContextTable]
        let overBudgetNames: [String]
    }

    static func render(
        _ snapshot: QueryContextSnapshot,
        columnLimit: Int = QueryContextBuilder.columnLimit,
        characterBudget: Int = QueryContextRenderer.characterBudget
    ) -> String {
        rendering(snapshot, columnLimit: columnLimit, characterBudget: characterBudget).text
    }

    static func rendering(
        _ snapshot: QueryContextSnapshot,
        columnLimit: Int = QueryContextBuilder.columnLimit,
        characterBudget: Int = QueryContextRenderer.characterBudget
    ) -> Rendering {
        var sections = [header(snapshot), usageNote(snapshot)]
        var used = 0
        var sent: [QueryContextTable] = []
        var overBudget: [String] = []
        for table in snapshot.tables {
            let section = tableSection(table, columnLimit: columnLimit)
            let length = (section as NSString).length
            guard used == 0 || used + length <= characterBudget else {
                overBudget.append(table.qualifiedName)
                continue
            }
            sections.append(section)
            sent.append(table)
            used += length
        }
        if let gaps = gapSection(snapshot, overBudget: overBudget) {
            sections.append(gaps)
        }
        if let plan = snapshot.explainPlan {
            sections.append("### Explain plan\n" + MarkdownFence.wrap(plan, language: "text"))
        }
        return Rendering(text: sections.joined(separator: "\n\n"), sentTables: sent, overBudgetNames: overBudget)
    }

    static func header(_ snapshot: QueryContextSnapshot) -> String {
        var engine = snapshot.engineName
        if let version = snapshot.serverVersion, !version.isEmpty {
            engine += " \(version)"
        }
        var lines = ["## Query context", "- Engine: \(engine)"]
        if let database = snapshot.databaseName {
            lines.append("- Database: \(database)")
        }
        if let schema = snapshot.schemaName {
            lines.append("- Schema: \(schema)")
        }
        return lines.joined(separator: "\n")
    }

    static func tableSection(_ table: QueryContextTable, columnLimit: Int = QueryContextBuilder.columnLimit) -> String {
        var heading = "### \(table.qualifiedName)"
        var traits: [String] = []
        if let kind = table.kind, kind != .table {
            traits.append(kind.rawValue.lowercased())
        }
        if case .described(let structure) = table.content, let rows = structure.approximateRowCount {
            traits.append("~\(formatted(rows)) rows")
        }
        if !traits.isEmpty {
            heading += " (\(traits.joined(separator: ", ")))"
        }

        switch table.content {
        case .unavailable(let reason):
            return "\(heading)\nStructure unavailable: \(singleLine(reason))"
        case .described(let structure):
            var parts = [heading, columnTable(structure.columns, limit: columnLimit)]
            if let indexes = indexSection(structure) {
                parts.append(indexes)
            }
            if let keys = foreignKeySection(structure) {
                parts.append(keys)
            }
            return parts.joined(separator: "\n\n")
        }
    }

    static func columnTable(_ columns: [QueryContextColumn], limit: Int) -> String {
        guard !columns.isEmpty else { return "No columns reported." }
        var lines = [
            "| Column | Type | Nullable | Key | Default | Comment |",
            "| --- | --- | --- | --- | --- | --- |"
        ]
        for column in columns.prefix(limit) {
            let defaultValue = column.generationExpression.map { "generated: \($0)" } ?? column.defaultValue
            lines.append(
                "| \(MarkdownFence.tableCell(column.name)) | \(MarkdownFence.tableCell(column.dataType)) "
                    + "| \(column.isNullable ? "yes" : "no") | \(column.isPrimaryKey ? "PK" : "") "
                    + "| \(MarkdownFence.tableCell(defaultValue)) | \(MarkdownFence.tableCell(column.comment)) |"
            )
        }
        if columns.count > limit {
            lines.append("")
            lines.append("… and \(columns.count - limit) more columns not listed.")
        }
        return lines.joined(separator: "\n")
    }

    static func indexLine(_ index: QueryContextIndex) -> String {
        var line = "- \(index.name) (\(index.columns.joined(separator: ", ")))"
        var flags: [String] = []
        if index.isPrimary { flags.append("primary") }
        if index.isUnique, !index.isPrimary { flags.append("unique") }
        if let method = index.method, !method.isEmpty { flags.append(method.lowercased()) }
        if !index.includedColumns.isEmpty { flags.append("include \(index.includedColumns.joined(separator: ", "))") }
        if !index.isValid { flags.append("invalid, not used by the planner") }
        if !flags.isEmpty { line += " [\(flags.joined(separator: ", "))]" }
        if let predicate = index.predicate, !predicate.isEmpty {
            line += " where \(singleLine(predicate))"
        }
        return line
    }

    static func foreignKeyLine(_ key: QueryContextForeignKey) -> String {
        var target = key.referencedTable
        if let schema = key.referencedSchema, !schema.isEmpty {
            target = "\(schema).\(target)"
        }
        var line = "- (\(key.columns.joined(separator: ", "))) -> \(target)(\(key.referencedColumns.joined(separator: ", ")))"
        var rules: [String] = []
        if !isDefaultRule(key.onDelete) { rules.append("on delete \(key.onDelete.lowercased())") }
        if !isDefaultRule(key.onUpdate) { rules.append("on update \(key.onUpdate.lowercased())") }
        if !rules.isEmpty { line += " \(rules.joined(separator: ", "))" }
        return line
    }

    private static func usageNote(_ snapshot: QueryContextSnapshot) -> String {
        guard !snapshot.tables.isEmpty else {
            return "No table structure could be read for this query. Say so rather than guessing column names."
        }
        return "Use only the tables and columns listed here. If the query names something that is not listed, "
            + "say so instead of guessing. Row counts are estimates."
    }

    private static func indexSection(_ structure: QueryContextTableStructure) -> String? {
        if let reason = structure.indexesUnavailableReason {
            return "Indexes: unavailable (\(singleLine(reason)))"
        }
        guard !structure.indexes.isEmpty else { return "Indexes: none" }
        return "Indexes:\n" + structure.indexes.map(indexLine).joined(separator: "\n")
    }

    private static func foreignKeySection(_ structure: QueryContextTableStructure) -> String? {
        if let reason = structure.foreignKeysUnavailableReason {
            return "Foreign keys: unavailable (\(singleLine(reason)))"
        }
        guard !structure.foreignKeys.isEmpty else { return nil }
        return "Foreign keys:\n" + structure.foreignKeys.map(foreignKeyLine).joined(separator: "\n")
    }

    private static func gapSection(_ snapshot: QueryContextSnapshot, overBudget: [String]) -> String? {
        var lines: [String] = []
        let scope = [snapshot.databaseName, snapshot.schemaName].compactMap { $0 }.joined(separator: ".")
        if !snapshot.notFound.isEmpty {
            let place = scope.isEmpty ? "" : " in \(scope)"
            lines.append("- Not found\(place): \(snapshot.notFound.joined(separator: ", "))")
        }
        if !snapshot.outsideScope.isEmpty {
            lines.append("- In another database, not described: \(snapshot.outsideScope.joined(separator: ", "))")
        }
        if !snapshot.notDescribed.isEmpty {
            lines.append(
                "- Not described, over the limit of \(QueryContextBuilder.tableLimit) tables: "
                    + snapshot.notDescribed.joined(separator: ", ")
            )
        }
        if !overBudget.isEmpty {
            lines.append("- Not described, too large to send in full: \(overBudget.joined(separator: ", "))")
        }
        guard !lines.isEmpty else { return nil }
        return "### Tables without structure\n" + lines.joined(separator: "\n")
    }

    private static func isDefaultRule(_ rule: String) -> Bool {
        let normalized = rule.uppercased()
        return normalized.isEmpty || normalized == "NO ACTION" || normalized == "RESTRICT"
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private static func formatted(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
