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
        let withFixes = findings.filter { finding in
            guard let fix = finding.fixSQL else { return false }
            return !fix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let kept = keptRedundantIndexes(withFixes)
        // An index both unused and redundant has one drop for two findings; run twice, the second fails. The fix
        // runs once, under the comment line of every finding it fixes.
        var blocks: [(comments: [String], fix: String?)] = []
        var blockForFix: [String: Int] = [:]
        for finding in withFixes {
            guard let fix = finding.fixSQL else { continue }
            let name = commentLine(String(format: String(localized: "%1$@: %2$@"), checkTitle(finding.kind), finding.qualifiedName))
            if let cover = kept[finding.id] {
                let note = String(format: String(localized: "Not dropped: its covering index %@ is dropped in this script."), cover)
                blocks.append((comments: [name, commentLine(note)], fix: nil))
                continue
            }
            let statement = fix.trimmingCharacters(in: .whitespacesAndNewlines)
            if let block = blockForFix[statement] {
                blocks[block].comments.append(name)
            } else {
                blockForFix[statement] = blocks.count
                blocks.append((comments: [name], fix: fix))
            }
        }
        for block in blocks {
            script += "\n\n" + block.comments.joined(separator: "\n")
            if let fix = block.fix {
                script += "\n" + fix
            }
        }
        return script + "\n"
    }

    private struct IndexKey: Hashable {
        let schema: String?
        let table: String?
        let name: String
    }

    // A redundant index whose covering index this script drops too stays, or the script would drop both and leave
    // the lookups they serve with no index: an unused composite covering a single-column index that queries use is
    // the common case. Returns each kept finding with its covering index's name.
    private static func keptRedundantIndexes(_ findings: [TableHealthFinding]) -> [TableHealthFindingID: String] {
        var unusedDrops: Set<IndexKey> = []
        var redundant: [IndexKey: (id: TableHealthFindingID, cover: IndexKey, coverName: String)] = [:]
        for finding in findings {
            guard let name = finding.objectName else { continue }
            let key = IndexKey(schema: finding.schema, table: finding.table, name: name)
            switch finding.kind {
            case .unusedIndex:
                unusedDrops.insert(key)
            case .redundantIndex:
                guard case .text(let cover)? = finding.metric("covering_index")?.value else { continue }
                redundant[key] = (finding.id, IndexKey(schema: finding.schema, table: finding.table, name: cover), cover)
            default:
                continue
            }
        }
        // Covers point from an index to one that serves at least its lookups, never back, so the walk ends; the
        // visited set only guards against a malformed report.
        func isDropped(_ key: IndexKey, visited: Set<IndexKey>) -> Bool {
            if unusedDrops.contains(key) { return true }
            guard let entry = redundant[key], !visited.contains(key) else { return false }
            return !isDropped(entry.cover, visited: visited.union([key]))
        }
        var kept: [TableHealthFindingID: String] = [:]
        for (key, entry) in redundant where !unusedDrops.contains(key) && isDropped(entry.cover, visited: [key]) {
            kept[entry.id] = entry.coverName
        }
        return kept
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
