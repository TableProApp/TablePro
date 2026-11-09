import Foundation

enum TableHealthFixScript {
    static func script(
        database: String,
        generatedAt date: Date,
        databaseType: DatabaseType,
        findings: [TableHealthFinding],
        checkTitle: (TableHealthCheckKind) -> String = { $0.title }
    ) -> String {
        var script = [
            commentLine(String(format: String(localized: "Database: %1$@ (%2$@)"), database, databaseType.displayName)),
            commentLine(String(format: String(localized: "Generated: %@"), date.formatted(.iso8601))),
            commentLine(String(localized: "Run each statement on its own; some cannot run inside a transaction."))
        ].joined(separator: "\n")
        // An index both unused and redundant has one drop for two findings; run twice, the second fails. The fix
        // runs once, under the comment line of every finding it fixes.
        var blocks: [(comments: [String], fix: String)] = []
        var blockForFix: [String: Int] = [:]
        for finding in findings {
            guard let fix = finding.fixSQL else { continue }
            let statement = fix.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !statement.isEmpty else { continue }
            let name = String(format: String(localized: "%1$@: %2$@"), checkTitle(finding.kind), finding.qualifiedName)
            if let block = blockForFix[statement] {
                blocks[block].comments.append(commentLine(name))
            } else {
                blockForFix[statement] = blocks.count
                blocks.append((comments: [commentLine(name)], fix: fix))
            }
        }
        for block in blocks {
            script += "\n\n" + block.comments.joined(separator: "\n") + "\n" + block.fix
        }
        return script + "\n"
    }

    // A name can hold any character. Flattened and with its comment markers broken, it cannot end the comment early or
    // open a MySQL /*! ... */ comment the server would run.
    static func commentLine(_ text: String) -> String {
        let flat = singleLine(text)
            .replacingOccurrences(of: "/*", with: "/ *")
            .replacingOccurrences(of: "*/", with: "* /")
        return "-- " + flat
    }

    static func singleLine(_ text: String) -> String {
        String(text.map { $0.isNewline || $0 == "\t" ? " " : $0 })
    }
}
