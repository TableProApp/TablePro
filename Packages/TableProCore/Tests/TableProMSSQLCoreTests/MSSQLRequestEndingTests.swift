import Foundation
import Testing

@testable import TableProMSSQLCore

@Suite("MSSQL request ending")
struct MSSQLRequestEndingTests {
    private static func answer(_ cells: [MSSQLRawCell]) -> MSSQLRawResult {
        MSSQLRawResult(
            columns: cells.indices.map { MSSQLColumnDescriptor(name: "c\($0)", type: .int) },
            rows: [cells],
            affectedRows: 1,
            isTruncated: false
        )
    }

    private static func ending(tranCount: String, xactAbort: String) -> MSSQLRequestEnding {
        MSSQLRequestEnding(sessionAnswer: answer([.string(tranCount), .string(xactAbort)]))
    }

    @Test("The session question asks for the open transactions and the XACT_ABORT bit")
    func sessionQueryAsksForBoth() {
        #expect(MSSQLRequestEnding.sessionQuery == "SELECT @@TRANCOUNT, @@OPTIONS & 16384")
    }

    @Test("An open transaction under XACT_ABORT reads the rest, because an attention rolls it back")
    func openTransactionUnderXactAbortReadsTheRest() {
        #expect(Self.ending(tranCount: "1", xactAbort: "16384") == .readRest)
        #expect(Self.ending(tranCount: "3", xactAbort: "16384") == .readRest)
    }

    @Test("An open transaction without XACT_ABORT survives an attention")
    func openTransactionWithoutXactAbortTakesAnAttention() {
        #expect(Self.ending(tranCount: "1", xactAbort: "0") == .attention)
    }

    @Test("XACT_ABORT with no open transaction has nothing to roll back")
    func xactAbortWithoutTransactionTakesAnAttention() {
        #expect(Self.ending(tranCount: "0", xactAbort: "16384") == .attention)
    }

    @Test("A session holding nothing takes an attention")
    func idleSessionTakesAnAttention() {
        #expect(Self.ending(tranCount: "0", xactAbort: "0") == .attention)
    }

    @Test("Padding around a converted number is read")
    func paddedNumbersAreRead() {
        #expect(Self.ending(tranCount: " 1 ", xactAbort: "16384 ") == .readRest)
        #expect(Self.ending(tranCount: " 0", xactAbort: " 0 ") == .attention)
    }

    @Test("No answer reads the rest")
    func missingAnswerReadsTheRest() {
        #expect(MSSQLRequestEnding(sessionAnswer: nil) == .readRest)
        let empty = MSSQLRawResult(columns: [], rows: [], affectedRows: 0, isTruncated: false)
        #expect(MSSQLRequestEnding(sessionAnswer: empty) == .readRest)
    }

    @Test("An answer the session did not give to this question reads the rest")
    func unreadableAnswerReadsTheRest() {
        #expect(MSSQLRequestEnding(sessionAnswer: Self.answer([.string("0")])) == .readRest)
        #expect(MSSQLRequestEnding(sessionAnswer: Self.answer([.string("<ShowPlanXML/>")])) == .readRest)
        #expect(MSSQLRequestEnding(sessionAnswer: Self.answer([.null, .string("0")])) == .readRest)
        #expect(MSSQLRequestEnding(sessionAnswer: Self.answer([.string("0"), .null])) == .readRest)
        #expect(MSSQLRequestEnding(sessionAnswer: Self.answer([.string("zero"), .string("0")])) == .readRest)
    }
}
