//
//  SQLExportStatementBudgetTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// The budget only means something if the number it counts is the number the file gets, so every
/// case here re-measures the statement it was handed rather than trusting the accumulator's tally.
@Suite("SQL export statement budget")
struct SQLExportStatementBudgetTests {
    private static let prefix = "INSERT INTO `t` (`id`, `payload`) VALUES\n"
    private static let upsertSuffix = "\nON DUPLICATE KEY UPDATE `payload` = VALUES(`payload`)"

    /// mysqldump's own `net_buffer_length`, so a fixture measured against it can be compared here.
    private static let mysqldumpBudget = 1_046_528

    private struct Run {
        let statements: [String]
        let largestStatementBytes: Int
        let largestStatementRows: Int
        let oversizedRowCount: Int
    }

    private func drive(
        rows: [String],
        prefix: String = Self.prefix,
        suffix: String = "",
        maxRows: Int = 500,
        maxBytes: Int
    ) -> Run {
        let accumulator = SQLExportStatementAccumulator(
            prefix: prefix,
            suffix: suffix,
            budget: SQLExportStatementBudget(maxRows: maxRows, maxBytes: maxBytes))
        var statements: [String] = []
        for row in rows {
            if let statement = accumulator.append(row) { statements.append(statement) }
        }
        if let statement = accumulator.finish() { statements.append(statement) }
        return Run(
            statements: statements,
            largestStatementBytes: accumulator.largestStatementBytes,
            largestStatementRows: accumulator.largestStatementRows,
            oversizedRowCount: accumulator.oversizedRowCount)
    }

    private func tuple(payloadBytes: Int, id: Int = 1) -> String {
        "  (\(id), '\(String(repeating: "x", count: payloadBytes))')"
    }

    private func rowCount(in statement: String, prefix: String = Self.prefix) -> Int {
        statement.hasPrefix(prefix) ? statement.components(separatedBy: ",\n").count : 0
    }

    /// The one assertion the whole feature rests on. Everything the accumulator reports about size
    /// is computed while rows go in; if that arithmetic and the rendered text ever disagree, a cap
    /// set to a server's limit stops meaning the server's limit.
    @Test("The size it counts is the size it wrote")
    func accountedBytesMatchTheRenderedStatement() {
        let fixtures: [(rows: [String], suffix: String, maxRows: Int, maxBytes: Int)] = [
            ((0 ..< 40).map { tuple(payloadBytes: 100_000, id: $0) }, "", 500, 1 << 20),
            ((0 ..< 1_000).map { tuple(payloadBytes: 3, id: $0) }, "", 500, 1 << 20),
            ((0 ..< 40).map { tuple(payloadBytes: 100_000, id: $0) }, Self.upsertSuffix, 500, 1 << 20),
            ((0 ..< 5).map { tuple(payloadBytes: 10, id: $0) }, "", 1, 1 << 20),
            ((0 ..< 40).map { tuple(payloadBytes: 100_000, id: $0) }, "", 500, 0),
            ((0 ..< 200).map { "  (\($0), '\(String(repeating: "😀", count: 100))')" }, "", 500, 8_192)
        ]
        for fixture in fixtures {
            let run = drive(
                rows: fixture.rows, suffix: fixture.suffix,
                maxRows: fixture.maxRows, maxBytes: fixture.maxBytes)
            let rendered = run.statements.map { $0.utf8.count }.max() ?? 0
            #expect(
                rendered == run.largestStatementBytes,
                "counted \(run.largestStatementBytes) but wrote \(rendered)")
        }
    }

    @Test("No statement passes the limit, and every statement but the last is as full as it can be")
    func theLimitIsACeilingRatherThanATrigger() {
        let rows = (0 ..< 40).map { tuple(payloadBytes: 100_000, id: $0) }
        let run = drive(rows: rows, maxBytes: Self.mysqldumpBudget)
        #expect(run.statements.count > 1)
        for statement in run.statements {
            #expect(statement.utf8.count <= Self.mysqldumpBudget)
        }
        for statement in run.statements.dropLast() {
            let oneMore = statement.utf8.count + 2 + rows[0].utf8.count
            #expect(oneMore > Self.mysqldumpBudget, "a statement closed with room for another row")
        }
    }

    /// mysqldump, measured on rows of 100,000 bytes at this budget, puts 10 in a statement. The
    /// arithmetic here has to land on the same number or the cap does not mean what it says.
    @Test("Rows of 100,000 bytes pack ten per statement, as mysqldump packs them")
    func packingMatchesMysqldump() {
        let rows = (0 ..< 32).map { tuple(payloadBytes: 100_000, id: $0) }
        let run = drive(rows: rows, maxBytes: Self.mysqldumpBudget)
        #expect(run.statements.map { rowCount(in: $0) } == [10, 10, 10, 2])
        #expect(run.largestStatementRows == 10)
    }

    @Test("Narrow rows close on the row count and wide rows close on the size, on one budget")
    func whicheverLimitComesFirstCloses() {
        let budget = 1 << 20
        let narrow = drive(rows: (0 ..< 1_000).map { tuple(payloadBytes: 3, id: $0) }, maxBytes: budget)
        #expect(narrow.statements.count == 2)
        #expect(narrow.largestStatementRows == 500)
        #expect(narrow.largestStatementBytes < budget)

        let wide = drive(rows: (0 ..< 40).map { tuple(payloadBytes: 100_000, id: $0) }, maxBytes: budget)
        #expect(wide.largestStatementRows < 500)
        #expect(wide.statements.allSatisfy { $0.utf8.count <= budget })
    }

    /// A `Character` budget is not a byte budget: measured, the same emoji rows admit 3.5 times the
    /// bytes under one. `max_allowed_packet` counts bytes on the wire.
    @Test("The budget counts UTF-8 bytes, not characters")
    func multiByteRowsAreMeasuredInBytes() {
        let rows = (0 ..< 200).map { "  (\($0), '\(String(repeating: "😀", count: 100))')" }
        let run = drive(rows: rows, maxBytes: 8_192)
        let widestInCharacters = run.statements.map(\.count).max() ?? 0
        #expect(run.largestStatementBytes <= 8_192)
        #expect(widestInCharacters < run.largestStatementBytes / 2)
    }

    /// A blob goes into the dump as hex, so its literal is twice its own length plus the wrapper.
    /// A budget that measured the value instead of the literal would be out by half.
    @Test("A blob's doubled hex literal counts toward the limit")
    func binaryLiteralsCountTheirRenderedLength() {
        let encoder = SQLExportRowValueEncoder(
            columns: ["id", "payload"],
            columnTypeNames: ["INT", "BLOB"],
            excludedColumnNames: [],
            databaseTypeId: "MySQL",
            escapeStringLiteral: { $0 })
        let blob = Data(repeating: 0xAB, count: 120_000)
        let rendered = encoder.render([.text("1"), .bytes(blob)])
        #expect(rendered.utf8.count > 240_000)

        let run = drive(rows: Array(repeating: rendered, count: 20), maxBytes: 1 << 20)
        #expect(run.largestStatementRows == 4)
        #expect(run.statements.allSatisfy { $0.utf8.count <= 1 << 20 })
    }

    /// A row cannot be split, so the limit cannot always hold. It is reported rather than hidden.
    @Test("A row larger than the whole limit is still written, alone, and counted")
    func anOversizedRowIsWrittenAndReported() {
        let huge = tuple(payloadBytes: 2_000_000, id: 1)
        let small = tuple(payloadBytes: 5, id: 2)
        let run = drive(rows: [huge, small], maxBytes: 1 << 20)
        #expect(run.statements.count == 2)
        #expect(run.oversizedRowCount == 1)
        #expect(run.largestStatementBytes > 1 << 20)
        #expect(run.statements.joined().contains(String(repeating: "x", count: 2_000_000)))
    }

    /// The suffix is part of the statement, and an upsert's trailing clause is not small. Counting
    /// only the values would spend it twice.
    @Test("A long suffix closes the statement earlier")
    func theSuffixIsCounted() {
        let rows = (0 ..< 200).map { tuple(payloadBytes: 1_000, id: $0) }
        let bare = drive(rows: rows, maxBytes: 8_192)
        let upsert = drive(rows: rows, suffix: Self.upsertSuffix, maxBytes: 8_192)
        #expect(upsert.largestStatementRows <= bare.largestStatementRows)
        #expect(upsert.statements.allSatisfy { $0.utf8.count <= 8_192 })
    }

    @Test("No byte limit writes one statement per row-count batch, as the export used to")
    func zeroBytesRestoresRowCountOnlyBatching() {
        let rows = (0 ..< 40).map { tuple(payloadBytes: 100_000, id: $0) }
        let run = drive(rows: rows, maxBytes: 0)
        #expect(run.statements.count == 1)
        #expect(run.largestStatementRows == 40)
        #expect(run.oversizedRowCount == 0)
    }

    @Test("One row per INSERT writes one statement per row")
    func aRowCapOfOneNeverBatches() {
        let run = drive(rows: (0 ..< 5).map { tuple(payloadBytes: 10, id: $0) }, maxRows: 1, maxBytes: 1 << 20)
        #expect(run.statements.count == 5)
        #expect(run.largestStatementRows == 1)
    }

    @Test("An accumulator handed nothing writes nothing")
    func anEmptyTableClosesNoStatement() {
        let accumulator = SQLExportStatementAccumulator(
            prefix: Self.prefix, suffix: "",
            budget: SQLExportStatementBudget(maxRows: 500, maxBytes: 1 << 20))
        #expect(accumulator.finish() == nil)
        #expect(accumulator.largestStatementBytes == 0)
    }

    @Test("A budget cannot be built with fewer than one row or negative bytes")
    func theBudgetClampsItsOwnInputs() {
        #expect(SQLExportStatementBudget(maxRows: 0, maxBytes: -1).maxRows == 1)
        #expect(SQLExportStatementBudget(maxRows: -5, maxBytes: -1).maxBytes == 0)
    }

    /// The tally travels out of the export rather than living on the plugin, because
    /// `PluginManager.exportPlugin(forFormat:)` hands every window the same instance. It carries the
    /// limit it was measured against for the same reason: the setting behind that limit is mutable.
    @Test("A tally carries the limit it was measured against, not whatever the setting says later")
    func theTallyCarriesItsOwnLimit() {
        let accumulator = SQLExportStatementAccumulator(
            prefix: Self.prefix, suffix: "",
            budget: SQLExportStatementBudget(maxRows: 500, maxBytes: 1_024))
        _ = accumulator.append(tuple(payloadBytes: 4_000))
        _ = accumulator.finish()

        let tally = accumulator.tally
        #expect(tally.limitBytes == 1_024)
        #expect(tally.oversizedRowCount == 1)
        #expect(tally.largestStatementBytes > 1_024)
    }

    @Test("Merging tallies keeps the largest statement with its own row count and sums the oversized")
    func tallesMergeWithoutCrossingTheirFigures() {
        var first = SQLExportStatementTally(
            largestStatementBytes: 900, largestStatementRows: 3, oversizedRowCount: 1, limitBytes: 1_024)
        let second = SQLExportStatementTally(
            largestStatementBytes: 1_500, largestStatementRows: 7, oversizedRowCount: 2, limitBytes: 1_024)

        first.merge(second)
        #expect(first.largestStatementBytes == 1_500)
        #expect(first.largestStatementRows == 7)
        #expect(first.oversizedRowCount == 3)

        var wider = second
        wider.merge(SQLExportStatementTally(
            largestStatementBytes: 100, largestStatementRows: 1, oversizedRowCount: 0, limitBytes: 1_024))
        #expect(wider.largestStatementRows == 7, "a smaller statement must not take over the row count")
    }
}
