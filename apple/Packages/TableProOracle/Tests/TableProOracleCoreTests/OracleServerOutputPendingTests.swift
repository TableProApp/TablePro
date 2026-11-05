@testable import TableProOracleCore
import Testing

// The host reads DBMS_OUTPUT before and after every editor statement, and on Oracle each read is a round trip.
struct OracleServerOutputPendingTests {
    @Test func testANewSessionHasNothingToRead() {
        #expect(!OracleServerOutputPending().needsRead)
    }

    @Test func testAStatementLeavesOutputToRead() {
        var pending = OracleServerOutputPending()
        pending.noteStatement()
        #expect(pending.needsRead)
    }

    @Test func testOneReadTakesWhatEveryStatementBeforeItLeft() {
        var pending = OracleServerOutputPending()
        pending.noteStatement()
        pending.noteStatement()
        pending.noteRead()
        #expect(!pending.needsRead)
    }

    @Test func testAReadBeforeTheNextStatementFindsNothingNew() {
        var pending = OracleServerOutputPending()
        pending.noteStatement()
        pending.noteRead()
        pending.noteRead()
        #expect(!pending.needsRead)
    }

    @Test func testAStatementAfterAReadNeedsAnotherRead() {
        var pending = OracleServerOutputPending()
        pending.noteStatement()
        pending.noteRead()
        pending.noteStatement()
        #expect(pending.needsRead)
    }
}
