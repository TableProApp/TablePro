import Foundation

enum MCPPromptMarkdown {
    static func connectionHeader(_ target: MCPPromptTarget) -> String {
        var parts = [
            "Connection: \(target.connection.name) (\(target.connection.databaseType))",
            "Scope: \(target.scopeDescription)"
        ]
        if let serverVersion = target.serverVersion, !serverVersion.isEmpty {
            parts.append("Server version: \(serverVersion)")
        }
        parts.append("Safe mode: \(target.connection.safeMode)")
        return parts.map { "- \($0)" }.joined(separator: "\n")
    }

    static func inventory(_ tables: [MCPPromptTableEntry], limit: Int) -> String {
        guard !tables.isEmpty else { return "No tables found in this scope." }
        let shown = tables.prefix(limit)
        var lines = shown.map { entry -> String in
            let rows = entry.rowCount.map { " (~\(formatted($0)) rows)" } ?? ""
            return "- \(entry.name) [\(entry.type)]\(rows)"
        }
        if tables.count > shown.count {
            lines.append("- ... and \(tables.count - shown.count) more tables not listed here")
        }
        return lines.joined(separator: "\n")
    }

    static func tableSection(_ detail: MCPPromptTableDetail, includeDdl: Bool) -> String {
        var sections = ["### \(detail.name)"]
        if let rowCount = detail.approximateRowCount {
            sections.append("Approximate rows: \(formatted(rowCount))")
        }
        sections.append(columnTable(detail.columns))
        if !detail.indexes.isEmpty {
            sections.append("Indexes:\n" + indexList(detail.indexes))
        }
        if !detail.foreignKeys.isEmpty {
            sections.append("Foreign keys:\n" + foreignKeyList(detail.foreignKeys))
        }
        if includeDdl, let ddl = detail.ddl, !ddl.isEmpty {
            sections.append("DDL:\n```sql\n\(ddl)\n```")
        }
        return sections.joined(separator: "\n\n")
    }

    static func tableSections(_ details: [MCPPromptTableDetail], includeDdl: Bool) -> String {
        guard !details.isEmpty else { return "No table structure was available for this scope." }
        return details.map { tableSection($0, includeDdl: includeDdl) }.joined(separator: "\n\n")
    }

    static func columnTable(_ columns: [MCPPromptColumn]) -> String {
        guard !columns.isEmpty else { return "No columns reported." }
        var lines = [
            "| Column | Type | Nullable | Key | Default | Comment |",
            "| --- | --- | --- | --- | --- | --- |"
        ]
        for column in columns {
            lines.append(
                "| \(column.name) | \(column.dataType) | \(column.isNullable ? "yes" : "no") "
                    + "| \(column.isPrimaryKey ? "PK" : "") | \(escaped(column.defaultValue)) "
                    + "| \(escaped(column.comment)) |"
            )
        }
        return lines.joined(separator: "\n")
    }

    static func indexList(_ indexes: [MCPPromptIndex]) -> String {
        indexes.map { index in
            var flags: [String] = []
            if index.isPrimary { flags.append("primary") }
            if index.isUnique { flags.append("unique") }
            let suffix = flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"
            return "- \(index.name) (\(index.columns.joined(separator: ", ")))\(suffix)"
        }
        .joined(separator: "\n")
    }

    static func foreignKeyList(_ foreignKeys: [MCPPromptForeignKey]) -> String {
        foreignKeys
            .map { "- \($0.column) -> \($0.referencedTable).\($0.referencedColumn)" }
            .joined(separator: "\n")
    }

    static func historyTable(_ entries: [MCPPromptHistoryEntry]) -> String {
        guard !entries.isEmpty else { return "No query history was recorded for this period." }
        var lines = [
            "| Executed at | Database | Type | Source | Duration (ms) | Rows | Outcome |",
            "| --- | --- | --- | --- | --- | --- | --- |"
        ]
        for entry in entries {
            let outcome = entry.wasSuccessful ? "ok" : "failed: \(escaped(entry.errorMessage))"
            lines.append(
                "| \(entry.executedAt) | \(entry.databaseName) | \(entry.statementType) | \(entry.source) "
                    + "| \(Int(entry.executionTimeMilliseconds.rounded())) | \(entry.rowCount) | \(outcome) |"
            )
        }
        lines.append("")
        lines.append("Statements, newest first:")
        for entry in entries {
            lines.append("```sql\n\(truncated(entry.query, limit: 600))\n```")
        }
        return lines.joined(separator: "\n")
    }

    static func codeBlock(_ text: String, language: String) -> String {
        "```\(language)\n\(text)\n```"
    }

    static func truncated(_ text: String, limit: Int) -> String {
        let source = text as NSString
        guard source.length > limit else { return text }
        return source.substring(to: limit) + "\n... truncated"
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

    private static func escaped(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        return text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
