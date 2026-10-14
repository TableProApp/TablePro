import Foundation
@testable import TableProOracleCore
import Testing

/// Oracle commits nothing on its own, so a write the driver runs without the commit flag stays invisible to every
/// other session, and holds its locks, until something commits it. These pin when the flag is sent.
struct OracleSessionTransactionTests {
    @Test func testAWriteOutsideATransactionCommitsAsItRuns() throws {
        var transaction = OracleSessionTransaction()
        #expect(try transaction.admit(.other, on: 1))
        #expect(!transaction.isOpen)
    }

    @Test func testAQueryNeverCarriesACommit() throws {
        var transaction = OracleSessionTransaction()
        #expect(!(try transaction.admit(.query, on: 1)))
        transaction.open()
        #expect(!(try transaction.admit(.query, on: 1)))
    }

    @Test func testNothingCommitsInsideATransactionUntilItEnds() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        #expect(!(try transaction.admit(.other, on: 1)))
        #expect(!(try transaction.admit(.other, on: 1)))

        #expect(!(try transaction.admit(.endsTransaction, on: 1)))
        transaction.statementSucceeded(.endsTransaction, on: 1)
        #expect(!transaction.isOpen)
        #expect(try transaction.admit(.other, on: 1))
    }

    @Test func testACommitTheServerRolledBackEndsTheTransaction() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        _ = try transaction.admit(.other, on: 1)
        _ = try transaction.admit(.endsTransaction, on: 1)
        transaction.statementFailed(.endsTransaction, serverHoldsTransaction: false)
        #expect(!transaction.isOpen)
    }

    @Test func testAMalformedCommitLeavesTheTransactionOpen() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        _ = try transaction.admit(.other, on: 1)
        _ = try transaction.admit(.endsTransaction, on: 1)
        transaction.statementFailed(.endsTransaction, serverHoldsTransaction: true)
        #expect(transaction.isOpen)
        #expect(!(try transaction.admit(.other, on: 1)))
    }

    @Test func testACommitWithNoConnectionToAskLeavesTheTransactionToTheNextWrite() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        _ = try transaction.admit(.other, on: 1)
        _ = try transaction.admit(.endsTransaction, on: 1)
        transaction.statementFailed(.endsTransaction, serverHoldsTransaction: nil)
        #expect(transaction.isOpen)
        if let error = #expect(throws: (any Error).self, performing: { try transaction.admit(.other, on: 2) }) {
            #expect(error as? OracleCoreError == .transactionLost)
        }
    }

    @Test func testAFailedWriteLeavesTheTransactionOpen() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        _ = try transaction.admit(.other, on: 1)
        transaction.statementFailed(.other, serverHoldsTransaction: false)
        #expect(transaction.isOpen)
    }

    @Test func testACommitWithNoTransactionOpenIsSentAsIs() throws {
        var transaction = OracleSessionTransaction()
        #expect(!(try transaction.admit(.endsTransaction, on: 1)))
        transaction.statementSucceeded(.endsTransaction, on: 1)
        #expect(!transaction.isOpen)
    }

    @Test func testASavepointOpensATransactionOnceOracleAcceptsIt() throws {
        var transaction = OracleSessionTransaction()
        #expect(!(try transaction.admit(.opensTransaction, on: 1)))
        #expect(!transaction.isOpen)
        transaction.statementSucceeded(.opensTransaction, on: 1)
        #expect(transaction.isOpen)
        #expect(!(try transaction.admit(.other, on: 1)))
    }

    @Test func testARefusedSavepointOpensNothing() throws {
        var transaction = OracleSessionTransaction()
        _ = try transaction.admit(.opensTransaction, on: 1)
        transaction.statementFailed(.opensTransaction, serverHoldsTransaction: nil)
        #expect(!transaction.isOpen)
        #expect(try transaction.admit(.other, on: 1))
    }

    @Test func testAWriteOnAReplacedConnectionReportsTheTransactionLost() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        _ = try transaction.admit(.other, on: 1)

        if let error = #expect(throws: (any Error).self, performing: { try transaction.admit(.other, on: 2) }) {
            #expect(error as? OracleCoreError == .transactionLost)
        }
        #expect(!transaction.isOpen)
        #expect(try transaction.admit(.other, on: 2))
    }

    @Test func testACommitOnAReplacedConnectionReportsTheTransactionLost() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        _ = try transaction.admit(.other, on: 1)

        if let error = #expect(throws: (any Error).self, performing: { try transaction.admit(.endsTransaction, on: 2) }) {
            #expect(error as? OracleCoreError == .transactionLost)
        }
        #expect(!transaction.isOpen)
    }

    @Test func testATransactionBindsToTheConnectionOfItsFirstWriteNotItsFirstRead() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        _ = try transaction.admit(.query, on: 1)
        #expect(!(try transaction.admit(.other, on: 2)))
        #expect(throws: (any Error).self) { try transaction.admit(.other, on: 3) }
    }

    @Test func testAQueryOnAReplacedConnectionStillRuns() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        _ = try transaction.admit(.other, on: 1)
        #expect(!(try transaction.admit(.query, on: 2)))
        #expect(transaction.isOpen)
    }

    @Test func testOpeningAnOpenTransactionKeepsItsConnection() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        _ = try transaction.admit(.other, on: 1)
        transaction.open()
        #expect(throws: (any Error).self) { try transaction.admit(.other, on: 2) }
    }
}
