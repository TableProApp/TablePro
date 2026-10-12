import Foundation
import Testing

@testable import TableProMSSQLCore

@Suite("MSSQL batch readout")
struct MSSQLBatchReadoutTests {
    private static func message(number: Int, severity: Int, text: String = "text") -> MSSQLServerMessage {
        MSSQLServerMessage(number: number, severity: severity, state: 1, line: 1, procedure: "", text: text)
    }

    private static func resultSet(_ column: String, rows: Int) -> MSSQLRawResult {
        MSSQLRawResult(
            columns: [MSSQLColumnDescriptor(name: column, type: .int)],
            rows: Array(repeating: [.string("1")], count: rows),
            affectedRows: rows,
            isTruncated: false
        )
    }

    @Test("Severity above 10 is an error, 20 and above ends the connection")
    func severityClassifies() {
        #expect(!Self.message(number: 0, severity: 0).isError)
        #expect(!Self.message(number: 50_000, severity: 10).isError)
        #expect(Self.message(number: 208, severity: 16).isError)
        #expect(!Self.message(number: 208, severity: 16).endsConnection)
        #expect(Self.message(number: 50_000, severity: 20).endsConnection)
        #expect(Self.message(number: 596, severity: 21).endsConnection)
    }

    /// Measured: 5701 and 5703 arrive on every login and 5701 on every `USE`, whatever the script printed.
    @Test("PRINT output is output, a change of context is not")
    func contextChangesAreNotOutput() {
        #expect(Self.message(number: 0, severity: 0, text: "hello").isOutput)
        #expect(Self.message(number: 50_000, severity: 0, text: "info ten").isOutput)
        #expect(Self.message(number: 3_621, severity: 0).isOutput)
        #expect(!Self.message(number: 5_701, severity: 0).isOutput)
        #expect(!Self.message(number: 5_703, severity: 0).isOutput)
        #expect(!Self.message(number: 5_704, severity: 0).isOutput)
        #expect(!Self.message(number: 2_627, severity: 14).isOutput)
    }

    @Test("db-lib's connection-ending numbers")
    func libraryErrorsThatEndTheConnection() {
        #expect(MSSQLLibraryError.endsConnection(20_004))
        #expect(MSSQLLibraryError.endsConnection(20_006))
        #expect(MSSQLLibraryError.endsConnection(20_017))
        #expect(MSSQLLibraryError.endsConnection(20_047))
        #expect(!MSSQLLibraryError.endsConnection(MSSQLLibraryError.serverMessageNotice))
        #expect(!MSSQLLibraryError.endsConnection(20_019))
    }

    @Test("A single result is the first result set, with its own columns")
    func singleResultIsTheFirstResultSet() throws {
        let readout = MSSQLBatchReadout(
            resultSets: [Self.resultSet("a", rows: 2)],
            rowsAffected: 7,
            errors: [],
            errorsNotKept: 0,
            resultSetsReadPast: 0
        )
        let result = try readout.singleResult()
        #expect(result.columns.map(\.name) == ["a"])
        #expect(result.rows.count == 2)
        #expect(result.affectedRows == 2)
        #expect(result.resultSetsNotShown == 0)
    }

    @Test("Result sets a single result reads past are counted")
    func resultSetsReadPastAreCounted() throws {
        let readout = MSSQLBatchReadout(
            resultSets: [Self.resultSet("a", rows: 1)],
            rowsAffected: 0,
            errors: [],
            errorsNotKept: 0,
            resultSetsReadPast: 2
        )
        #expect(try readout.singleResult().resultSetsNotShown == 2)
    }

    @Test("A request with no result set answers with its counts")
    func countOnlyRequestReportsItsCounts() throws {
        let readout = MSSQLBatchReadout(resultSets: [], rowsAffected: 3, errors: [], errorsNotKept: 0, resultSetsReadPast: 0)
        let result = try readout.singleResult()
        #expect(result.columns.isEmpty)
        #expect(result.affectedRows == 3)
    }

    /// `SELECT 1/0` arrives as a result set with a column and no rows, and its error only through the message handler.
    /// Reporting that as an empty success hid the error.
    @Test("Any server error fails a single result, even with a result set beside it")
    func serverErrorFailsASingleResult() {
        let error = MSSQLPlacedError(
            message: Self.message(number: 8_134, severity: 16, text: "Divide by zero error encountered."),
            precedingResultSetCount: 1
        )
        let readout = MSSQLBatchReadout(
            resultSets: [Self.resultSet("one", rows: 1)],
            rowsAffected: 0,
            errors: [error],
            errorsNotKept: 0,
            resultSetsReadPast: 0
        )
        #expect {
            try readout.singleResult()
        } throws: { thrown in
            guard case MSSQLCoreError.queryFailed(let detail) = thrown else { return false }
            return detail == "Divide by zero error encountered."
        }
    }
}
