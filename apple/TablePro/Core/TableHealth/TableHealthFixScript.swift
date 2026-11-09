import Foundation

enum TableHealthFixScript {
    static func script(
        database: String,
        generatedAt date: Date,
        databaseType: DatabaseType,
        findings: [TableHealthFinding]
    ) -> String {
        var script = [
            commentLine(String(format: String(localized: "Database: %1$@ (%2$@)"), database, databaseType.displayName)),
            commentLine(String(format: String(localized: "Generated: %@"), date.formatted(.iso8601))),
            commentLine(String(localized: "Run each statement on its own; some cannot run inside a transaction."))
        ].joined(separator: "\n")
        for finding in findings {
            guard let fix = finding.fixSQL, !fix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let name = String(format: String(localized: "%1$@: %2$@"), finding.kind.title, finding.qualifiedName)
            script += "\n\n" + commentLine(name) + "\n" + fix
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
