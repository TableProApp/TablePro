import Foundation
import Testing

@testable import TableProMSSQLCore

struct MSSQLShowplanTests {
    private static func readout(_ resultSets: [MSSQLRawResult], errors: [String] = []) -> MSSQLBatchReadout {
        MSSQLBatchReadout(
            resultSets: resultSets,
            rowsAffected: 0,
            errors: errors.map {
                MSSQLPlacedError(
                    message: MSSQLServerMessage(number: 262, severity: 14, state: 4, line: 1, procedure: "", text: $0),
                    precedingResultSetCount: 0
                )
            },
            errorsNotKept: 0,
            resultSetsReadPast: 0
        )
    }

    private static func resultSet(_ column: String, _ values: [String]) -> MSSQLRawResult {
        MSSQLRawResult(
            columns: [MSSQLColumnDescriptor(name: column, type: .ntext)],
            rows: values.map { [.string($0)] },
            affectedRows: values.count,
            isTruncated: false
        )
    }

    @Test("Each variant turns its own setting on and off", arguments: [
        (MSSQLShowplan.estimated, "SET SHOWPLAN_XML ON", "SET SHOWPLAN_XML OFF"),
        (.actual, "SET STATISTICS XML ON", "SET STATISTICS XML OFF"),
    ])
    func settings(showplan: MSSQLShowplan, on: String, off: String) {
        #expect(showplan.onStatement == on)
        #expect(showplan.offStatement == off)
        #expect(MSSQLShowplan(rawValue: showplan.variantId) == showplan)
    }

    @Test("An actual plan is the server's plan column, not the statement's own rows, even when those hold plan XML")
    func actualKeepsOnlyThePlanColumn() throws {
        let readout = Self.readout([
            Self.resultSet("name", ["c1"]),
            Self.resultSet("query_plan", ["<ShowPlanXML cached/>"]),
            Self.resultSet(MSSQLShowplan.planColumnName, ["<ShowPlanXML a/>"]),
        ])
        #expect(try MSSQLShowplan.actual.planDocuments(in: readout) == ["<ShowPlanXML a/>"])
    }

    @Test("An actual plan whose column carries another name is still found rather than lost")
    func actualFallsBackToContent() throws {
        let readout = Self.readout([
            Self.resultSet("name", ["c1"]),
            Self.resultSet("Showplan", ["<ShowPlanXML a/>"]),
        ])
        #expect(try MSSQLShowplan.actual.planDocuments(in: readout) == ["<ShowPlanXML a/>"])
    }

    @Test("Under SHOWPLAN_XML nothing runs, so every plan document the batch returned is the plan")
    func estimatedKeepsEveryPlanDocument() throws {
        let readout = Self.readout([
            Self.resultSet(MSSQLShowplan.planColumnName, ["<ShowPlanXML a/>"]),
            Self.resultSet("", ["<ShowPlanXML b/>"]),
        ])
        #expect(try MSSQLShowplan.estimated.planDocuments(in: readout) == ["<ShowPlanXML a/>", "<ShowPlanXML b/>"])
    }

    @Test("A login without SHOWPLAN gets the server's reason, not an empty plan")
    func permissionErrorIsTheAnswer() {
        let readout = Self.readout([], errors: ["SHOWPLAN permission denied in database 'probe'."])
        let error = #expect(throws: MSSQLCoreError.self) {
            try MSSQLShowplan.estimated.planDocuments(in: readout)
        }
        guard case .queryFailed(let message)? = error else {
            Issue.record("Expected a query failure, got \(String(describing: error))")
            return
        }
        #expect(message == "SHOWPLAN permission denied in database 'probe'.")
    }

    @Test("A batch that returned no plan says so")
    func noPlanIsAnError() {
        #expect(throws: MSSQLCoreError.self) {
            try MSSQLShowplan.actual.planDocuments(in: Self.readout([Self.resultSet("n", ["1"])]))
        }
    }
}
