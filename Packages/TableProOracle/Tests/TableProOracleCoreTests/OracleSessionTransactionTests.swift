@testable import TableProOracleCore
import XCTest

/// Oracle commits nothing on its own, so a write the driver runs without the commit flag stays invisible to every
/// other session, and holds its locks, until something commits it. These pin when the flag is sent.
final class OracleSessionTransactionTests: XCTestCase {
    func testAWriteOutsideATransactionCommitsAsItRuns() throws {
        var transaction = OracleSessionTransaction()
        XCTAssertTrue(try transaction.admit(.other, on: 1))
        XCTAssertFalse(transaction.isOpen)
    }

    func testAQueryNeverCarriesACommit() throws {
        var transaction = OracleSessionTransaction()
        XCTAssertFalse(try transaction.admit(.query, on: 1))
        transaction.open()
        XCTAssertFalse(try transaction.admit(.query, on: 1))
    }

    func testNothingCommitsInsideATransactionUntilItEnds() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        XCTAssertFalse(try transaction.admit(.other, on: 1))
        XCTAssertFalse(try transaction.admit(.other, on: 1))

        XCTAssertFalse(try transaction.admit(.endsTransaction, on: 1))
        transaction.statementSucceeded(.endsTransaction, on: 1)
        XCTAssertFalse(transaction.isOpen)
        XCTAssertTrue(try transaction.admit(.other, on: 1))
    }

    func testACommitTheServerRolledBackEndsTheTransaction() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        _ = try transaction.admit(.other, on: 1)
        _ = try transaction.admit(.endsTransaction, on: 1)
        transaction.statementFailed(.endsTransaction, serverHoldsTransaction: false)
        XCTAssertFalse(transaction.isOpen)
    }

    func testAMalformedCommitLeavesTheTransactionOpen() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        _ = try transaction.admit(.other, on: 1)
        _ = try transaction.admit(.endsTransaction, on: 1)
        transaction.statementFailed(.endsTransaction, serverHoldsTransaction: true)
        XCTAssertTrue(transaction.isOpen)
        XCTAssertFalse(try transaction.admit(.other, on: 1))
    }

    func testACommitWithNoConnectionToAskLeavesTheTransactionToTheNextWrite() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        _ = try transaction.admit(.other, on: 1)
        _ = try transaction.admit(.endsTransaction, on: 1)
        transaction.statementFailed(.endsTransaction, serverHoldsTransaction: nil)
        XCTAssertTrue(transaction.isOpen)
        XCTAssertThrowsError(try transaction.admit(.other, on: 2)) { error in
            XCTAssertEqual(error as? OracleCoreError, .transactionLost)
        }
    }

    func testAFailedWriteLeavesTheTransactionOpen() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        _ = try transaction.admit(.other, on: 1)
        transaction.statementFailed(.other, serverHoldsTransaction: false)
        XCTAssertTrue(transaction.isOpen)
    }

    func testACommitWithNoTransactionOpenIsSentAsIs() throws {
        var transaction = OracleSessionTransaction()
        XCTAssertFalse(try transaction.admit(.endsTransaction, on: 1))
        transaction.statementSucceeded(.endsTransaction, on: 1)
        XCTAssertFalse(transaction.isOpen)
    }

    func testASavepointOpensATransactionOnceOracleAcceptsIt() throws {
        var transaction = OracleSessionTransaction()
        XCTAssertFalse(try transaction.admit(.opensTransaction, on: 1))
        XCTAssertFalse(transaction.isOpen)
        transaction.statementSucceeded(.opensTransaction, on: 1)
        XCTAssertTrue(transaction.isOpen)
        XCTAssertFalse(try transaction.admit(.other, on: 1))
    }

    func testARefusedSavepointOpensNothing() throws {
        var transaction = OracleSessionTransaction()
        _ = try transaction.admit(.opensTransaction, on: 1)
        transaction.statementFailed(.opensTransaction, serverHoldsTransaction: nil)
        XCTAssertFalse(transaction.isOpen)
        XCTAssertTrue(try transaction.admit(.other, on: 1))
    }

    func testAWriteOnAReplacedConnectionReportsTheTransactionLost() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        _ = try transaction.admit(.other, on: 1)

        XCTAssertThrowsError(try transaction.admit(.other, on: 2)) { error in
            XCTAssertEqual(error as? OracleCoreError, .transactionLost)
        }
        XCTAssertFalse(transaction.isOpen)
        XCTAssertTrue(try transaction.admit(.other, on: 2))
    }

    func testACommitOnAReplacedConnectionReportsTheTransactionLost() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        _ = try transaction.admit(.other, on: 1)

        XCTAssertThrowsError(try transaction.admit(.endsTransaction, on: 2)) { error in
            XCTAssertEqual(error as? OracleCoreError, .transactionLost)
        }
        XCTAssertFalse(transaction.isOpen)
    }

    func testATransactionBindsToTheConnectionOfItsFirstWriteNotItsFirstRead() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        _ = try transaction.admit(.query, on: 1)
        XCTAssertFalse(try transaction.admit(.other, on: 2))
        XCTAssertThrowsError(try transaction.admit(.other, on: 3))
    }

    func testAQueryOnAReplacedConnectionStillRuns() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        _ = try transaction.admit(.other, on: 1)
        XCTAssertFalse(try transaction.admit(.query, on: 2))
        XCTAssertTrue(transaction.isOpen)
    }

    func testOpeningAnOpenTransactionKeepsItsConnection() throws {
        var transaction = OracleSessionTransaction()
        transaction.open()
        _ = try transaction.admit(.other, on: 1)
        transaction.open()
        XCTAssertThrowsError(try transaction.admit(.other, on: 2))
    }
}
