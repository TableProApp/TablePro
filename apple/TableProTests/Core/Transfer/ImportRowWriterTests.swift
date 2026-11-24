import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// Answers a probe from how many rows hold each key, read from the probe's own parameters in order.
private final class RecordingExecutor: @unchecked Sendable {
    private(set) var statements: [SQLImportStatement] = []
    private(set) var purposes: [ImportRowWriter.Purpose] = []
    private let rowsPerKey: [String: Int]

    init(rowsPerKey: [String: Int] = [:]) {
        self.rowsPerKey = rowsPerKey
    }

    var host: ImportRowWriter.Host {
        ImportRowWriter.Host(
            execute: { statement, purpose in
                self.statements.append(statement)
                self.purposes.append(purpose)
                guard purpose == .matchProbe else { return [] }
                return statement.parameters.enumerated().map { position, key -> [String?] in
                    [String(position), String(self.rowsPerKey[key.asText ?? ""] ?? 0)]
                }
            },
            columnsUpdateCannotSet: { [] },
            isCancelled: { false }
        )
    }

    var sql: [String] { statements.map(\.sql) }
}

struct ImportRowWriterTests {
    private var target: ImportRowWriter.Target {
        ImportRowWriter.Target(
            tableName: "people",
            statements: SQLImportStatements(
                databaseTypeId: "PostgreSQL",
                qualifiedTableName: "\"people\"",
                parameterStyle: .dollar,
                quoteIdentifier: { "\"\($0)\"" }
            ),
            values: ImportTargetValues(
                columns: [],
                binaryText: nil,
                prefixedHex: { _ in .notHex },
                traits: { _ in ImportTargetValues.ColumnTraits(holdsBytes: false, takesNumericBooleans: false) }
            )
        )
    }

    private let rows: [[String: PluginCellValue]] = [
        ["id": "1", "name": "Ada"],
        ["id": "2", "name": "Grace"],
    ]

    private func makeWriter(_ mode: ImportWriteMode) -> ImportRowWriter {
        ImportRowWriter(
            databaseTypeId: "PostgreSQL",
            columnMapping: ["id": "id", "name": "name"],
            sourceFields: ["id", "name"],
            rowWriting: ImportRowWriting(mode: mode, keyColumns: mode == .insert ? [] : ["id"])
        )
    }

    private let probe = """
        SELECT 0, COUNT(*) FROM "people" WHERE "id" = $1 UNION ALL SELECT 1, COUNT(*) FROM "people" WHERE "id" = $2
        """

    @Test("Insert writes the rows in one multi-row statement")
    func insertWritesOneBatch() async throws {
        let executor = RecordingExecutor()
        let writer = makeWriter(.insert)
        try await writer.insertRows(rows, into: target, host: executor.host)
        #expect(executor.sql == ["INSERT INTO \"people\" (\"id\", \"name\") VALUES ($1, $2), ($3, $4)"])
        #expect(executor.purposes == [.write(rows: 2)])
        #expect(executor.statements.first?.parameters == ["1", "Ada", "2", "Grace"])
        #expect(writer.tally.inserted == 2)
    }

    @Test("Update writes the matched row and leaves out the one that matches nothing")
    func updateSkipsUnmatched() async throws {
        let executor = RecordingExecutor(rowsPerKey: ["1": 1])
        let writer = makeWriter(.update)
        try await writer.insertRows(rows, into: target, host: executor.host)
        #expect(executor.sql == [probe, "UPDATE \"people\" SET \"name\" = $1 WHERE \"id\" = $2"])
        #expect(executor.purposes == [.matchProbe, .write(rows: 1)])
        #expect(writer.tally.updated == 1)
        #expect(writer.tally.unmatched == 1)
        #expect(writer.tally.inserted == 0)
    }

    @Test("Insert or Update updates the matched row and inserts the other, in file order")
    func upsertUpdatesThenInserts() async throws {
        let executor = RecordingExecutor(rowsPerKey: ["1": 1])
        let writer = makeWriter(.upsert)
        try await writer.insertRows(rows, into: target, host: executor.host)
        #expect(executor.sql == [
            probe,
            "UPDATE \"people\" SET \"name\" = $1 WHERE \"id\" = $2",
            "INSERT INTO \"people\" (\"id\", \"name\") VALUES ($1, $2)",
        ])
        #expect(writer.tally.updated == 1)
        #expect(writer.tally.inserted == 1)
    }

    @Test("Insert, Skip Existing inserts only the row the table does not hold")
    func skipExistingInsertsOnlyNewRows() async throws {
        let executor = RecordingExecutor(rowsPerKey: ["1": 1])
        let writer = makeWriter(.insertSkippingExisting)
        try await writer.insertRows(rows, into: target, host: executor.host)
        #expect(executor.sql == [probe, "INSERT INTO \"people\" (\"id\", \"name\") VALUES ($1, $2)"])
        #expect(executor.statements.last?.parameters == ["2", "Grace"])
        #expect(writer.tally.existing == 1)
        #expect(writer.tally.inserted == 1)
    }

    @Test("A key that matches two rows fails the batch before anything is written")
    func keyMatchingTwoRowsFails() async throws {
        let executor = RecordingExecutor(rowsPerKey: ["1": 2])
        let writer = makeWriter(.update)
        do {
            try await writer.insertRows(rows, into: target, host: executor.host)
            Issue.record("The import went on past an ambiguous key")
        } catch PluginImportError.importFailed(let message) {
            #expect(message == "The key id = 1 matched 2 rows, so the row was not written.")
        }
        #expect(executor.purposes == [.matchProbe])
        #expect(writer.tally == ImportRowTally(mode: .update))
    }

    @Test("A key repeated in one batch is probed again after its first row is written")
    func repeatedKeySplitsTheRun() async throws {
        let executor = RecordingExecutor()
        let writer = makeWriter(.upsert)
        let repeated: [[String: PluginCellValue]] = [["id": "1", "name": "Ada"], ["id": "1", "name": "Ada L."]]
        try await writer.insertRows(repeated, into: target, host: executor.host)
        #expect(executor.purposes == [.matchProbe, .write(rows: 1), .matchProbe, .write(rows: 1)])
        #expect(writer.tally.inserted == 2)
    }

    @Test("Clearing the table first is refused when rows are matched")
    func clearingRefusedWhenMatching() throws {
        #expect(try makeWriter(.insert).clearingStatement(using: target.statements) == "DELETE FROM \"people\"")
        #expect(throws: PluginImportError.self) {
            try makeWriter(.upsert).clearingStatement(using: target.statements)
        }
    }
}
