import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private let previewSamples: [String] = [
    "",
    " ",
    "\n",
    " \t \r\n \u{2028} ",
    "SELECT 1",
    "SELECT 1;",
    "  SELECT 1;  \n",
    "\n\n   SELECT 1\n\n\n",
    "SELECT id,\r\n       name\r\n  FROM users\r\n",
    "a\u{2028}b\u{2029}c\u{85}d\u{0B}e\u{0C}f\rg",
    "\tSELECT\t1\t\n\t\tFROM t\t",
    "\u{3000}SELECT\u{A0}1\u{2003}\n\u{A0}",
    "abc\n\u{301}def",
    "SELECT" + String(repeating: " ", count: 300) + "1",
    "SELECT 1\u{37E}",
    "SELECT 1\u{600}",
    String(repeating: "a", count: 98) + "\u{600}",
    String(repeating: "a", count: 99),
    String(repeating: "a", count: 99) + ";",
    String(repeating: "a", count: 100),
    String(repeating: "a", count: 101),
    String(repeating: "a", count: 98) + "\u{1F600}",
    String(repeating: "a", count: 99) + "\u{1F600}",
    String(repeating: "a", count: 100) + "\u{301}",
    String(repeating: "a", count: 120) + "\u{37E}",
    String(repeating: "a", count: 159),
    String(repeating: "a", count: 160),
    String(repeating: "a", count: 161),
    String(repeating: "a", count: 158) + "\u{1F600}",
    String(repeating: "a", count: 159) + "\u{1F600}",
    String(repeating: "a", count: 159) + "e\u{301}x",
    String(repeating: "a", count: 160) + "\u{301}",
    String(repeating: "a", count: 158) + "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}b",
    String(repeating: "a", count: 159) + "\u{1F1FA}\u{1F1F8}\u{1F1EC}\u{1F1E7}",
    String(repeating: "a", count: 80) + "\n" + String(repeating: "b", count: 79) + "\n\u{301}c",
    "a" + String(repeating: "\u{301}", count: 400) + " b\nc",
    String(repeating: "a", count: 150) + String(repeating: " ", count: 200),
    String(repeating: "  SELECT col FROM t\r\n", count: 30),
    String(repeating: "word ", count: 40) + "\n\n" + String(repeating: "\t", count: 50),
]

struct QueryHistoryEntryTests {
    private func makeEntry(
        query: String,
        statementType: QueryHistoryStatementType? = nil,
        executionTime: TimeInterval = 0.1,
        rowCount: Int = 10,
        wasSuccessful: Bool = true
    ) -> QueryHistoryEntry {
        QueryHistoryEntry(
            query: query,
            connectionId: UUID(),
            databaseName: "test",
            databaseType: .postgresql,
            source: .editor,
            statementType: statementType,
            executionTime: executionTime,
            rowCount: rowCount,
            wasSuccessful: wasSuccessful
        )
    }

    @Test("queryPreview truncates long queries")
    func queryPreviewTruncatesLongQuery() {
        let entry = makeEntry(query: String(repeating: "SELECT ", count: 30))
        #expect(entry.queryPreview.hasSuffix("…"))
    }

    @Test("queryPreview preserves short queries")
    func queryPreviewPreservesShortQuery() {
        #expect(makeEntry(query: "SELECT 1").queryPreview == "SELECT 1;")
    }

    @Test("singleLinePreview collapses a multi-line statement onto one line")
    func singleLinePreviewCollapsesNewlines() {
        let entry = makeEntry(query: "SELECT id,\n       name\n  FROM users\n WHERE active = true")
        #expect(entry.singleLinePreview == "SELECT id, name FROM users WHERE active = true")
        #expect(entry.singleLinePreview.contains("\n") == false)
    }

    @Test("The previews read as splitting and rejoining the whole query did", arguments: previewSamples)
    func previewsMatchTheWholeQueryVersion(query: String) {
        let entry = makeEntry(query: query, statementType: .select)
        #expect(Array(entry.singleLinePreview.unicodeScalars) == Array(WholeQueryPreview.singleLine(query).unicodeScalars))
        #expect(Array(entry.queryPreview.unicodeScalars) == Array(WholeQueryPreview.query(query).unicodeScalars))
    }

    @Test("The previews read as splitting and rejoining the whole query did on generated queries")
    func previewsMatchTheWholeQueryVersionOnGeneratedQueries() {
        let pieces = [
            "a", "SELECT", " ", "  ", "\t", "\n", "\r", "\r\n", "\u{2028}", "\u{85}", "\u{3000}", "\u{A0}",
            "\u{1F600}", "\u{1F468}\u{200D}\u{1F469}", "e\u{301}", "\u{301}", "\u{600}", ";", "\u{37E}",
            "\u{1F1FA}\u{1F1F8}", "\u{0B}",
        ]
        var generator = SeededGenerator(seed: 0x5EED)
        var mismatches: [String] = []
        for _ in 0..<500 {
            var query = ""
            for _ in 0..<Int.random(in: 0...140, using: &generator) {
                query += pieces.randomElement(using: &generator) ?? ""
            }
            let entry = makeEntry(query: query, statementType: .select)
            if !entry.singleLinePreview.unicodeScalars.elementsEqual(WholeQueryPreview.singleLine(query).unicodeScalars) {
                mismatches.append("singleLinePreview of \(String(reflecting: query))")
            }
            if !entry.queryPreview.unicodeScalars.elementsEqual(WholeQueryPreview.query(query).unicodeScalars) {
                mismatches.append("queryPreview of \(String(reflecting: query))")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
    }

    // A fixed time limit cannot tell a slow runner from a slow preview, so a preview of a 1 MB query is timed against
    // one of a query of 1.4 KB. Both previews stop at their cut, so they take about as long; reading the whole query
    // takes hundreds of times longer. The fastest of five drops the samples a stall landed on.
    @Test("A 1 MB query previews about as fast as a short one")
    func previewCostDoesNotGrowWithTheQuery() {
        let line = "SELECT id, name, email FROM users WHERE id = 42 AND status = 'active';\n"
        let short = makeEntry(query: String(repeating: line, count: 20), statementType: .select)
        let long = makeEntry(query: String(repeating: line, count: 15_000), statementType: .select)
        #expect((long.query as NSString).length > 1_000_000)

        var shortPreviews = TimeInterval.infinity
        var longPreviews = TimeInterval.infinity
        for _ in 0..<5 {
            shortPreviews = min(shortPreviews, Self.secondsSpent(previewing: short))
            longPreviews = min(longPreviews, Self.secondsSpent(previewing: long))
        }

        #expect(long.singleLinePreview == short.singleLinePreview)
        #expect(long.queryPreview == short.queryPreview)
        #expect(longPreviews < shortPreviews * 4)
    }

    private static func secondsSpent(previewing entry: QueryHistoryEntry) -> TimeInterval {
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 {
            _ = entry.singleLinePreview
            _ = entry.queryPreview
        }
        return ProcessInfo.processInfo.systemUptime - start
    }

    @Test("statementType is classified from the query when not supplied")
    func statementTypeIsClassified() {
        #expect(makeEntry(query: "SELECT 1").statementType == .select)
        #expect(makeEntry(query: "insert into t values (1)").statementType == .insert)
        #expect(makeEntry(query: "  -- a comment\n UPDATE t SET a = 1").statementType == .update)
        #expect(makeEntry(query: "DROP TABLE t").statementType == .ddl)
    }

    @Test("a negative row count reads as unknown rather than zero rows")
    func negativeRowCountIsUnknown() {
        let entry = makeEntry(query: "ALTER TABLE t ADD COLUMN c INT", rowCount: -1)
        #expect(entry.hasKnownRowCount == false)
        #expect(entry.formattedRowCount == "–")
    }

    @Test("an unmeasured duration is reported as unmeasured, not as zero")
    func zeroDurationIsUnmeasured() {
        #expect(makeEntry(query: "SELECT 1", executionTime: 0).hasMeasuredDuration == false)
        #expect(makeEntry(query: "SELECT 1", executionTime: 0.02).hasMeasuredDuration)
    }

    @Test("formattedExecutionTime switches unit at one second")
    func formattedExecutionTimeUnits() {
        #expect(makeEntry(query: "SELECT 1", executionTime: 0.25).formattedExecutionTime == "250 ms")
        #expect(makeEntry(query: "SELECT 1", executionTime: 1.5).formattedExecutionTime == "1.50 s")
    }

    @Test("a sub-millisecond query reads as under a millisecond, not as zero")
    func subMillisecondDurationIsNotZero() {
        let entry = makeEntry(query: "SELECT 1", executionTime: 0.0004)
        #expect(entry.formattedExecutionTime == String(localized: "<1 ms"))
        #expect(entry.formattedExecutionTime.hasPrefix("0") == false)
    }

    @Test("a file-backed database shows its file name, not its whole path")
    func fileBackedDatabaseShowsFileName() {
        let entry = QueryHistoryEntry(
            query: "SELECT 1",
            connectionId: UUID(),
            databaseName: "/Users/someone/Library/Containers/tmp/Chinook.sqlite",
            databaseType: .sqlite,
            source: .editor,
            executionTime: 0.01,
            rowCount: 1,
            wasSuccessful: true
        )
        #expect(entry.databaseDisplayName == "Chinook.sqlite")
    }

    @Test("a server database name is left alone")
    func serverDatabaseNameIsUnchanged() {
        let entry = makeEntry(query: "SELECT 1")
        #expect(entry.databaseDisplayName == "test")
    }
}

// The previews as they were before they stopped reading at the cut, kept as the reference the new ones are compared
// with.
private enum WholeQueryPreview {
    static func singleLine(_ query: String) -> String {
        let collapsed = query
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if (collapsed as NSString).length > 160 {
            return String(collapsed.prefix(160)) + "…"
        }
        return collapsed
    }

    static func query(_ query: String) -> String {
        var trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.hasSuffix(";") {
            trimmed += ";"
        }
        if (trimmed as NSString).length > 100 {
            return String(trimmed.prefix(100)) + "…"
        }
        return trimmed
    }
}
