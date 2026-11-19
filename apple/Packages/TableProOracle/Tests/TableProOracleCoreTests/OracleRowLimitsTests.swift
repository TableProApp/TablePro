import OracleNIO
@testable import TableProOracleCore
import Testing

struct OracleRowLimitsTests {
    @Test("A read fetches a thousand rows per round trip and keeps its other options")
    func readFetchesInLargeBatches() {
        let options = OracleRowLimits.fetching(StatementOptions(autoCommit: true))

        #expect(options.arraySize == 1_000)
        #expect(options.autoCommit)
    }

    @Test("A page of a thousand rows learns the end of the result in its first response")
    func firstResponseReachesPastOneBatch() {
        #expect(OracleRowLimits.fetching(StatementOptions()).prefetchRows == 1_001)
    }

    @Test("A capped read asks for its whole budget in the first response")
    func cappedReadPrefetchesItsBudget() {
        let options = OracleRowLimits.fetching(StatementOptions(), rowBudget: 5_001)

        #expect(options.prefetchRows == 5_001)
        #expect(options.arraySize == 1_000)
    }

    @Test("A budget under one batch does not ask for more than it reads")
    func smallBudgetStaysSmall() {
        #expect(OracleRowLimits.fetching(StatementOptions(), rowBudget: 101).prefetchRows == 101)
    }

    @Test("A very large budget stops at what one response may carry")
    func largeBudgetIsBounded() {
        let options = OracleRowLimits.fetching(StatementOptions(), rowBudget: 2_000_001)

        #expect(options.prefetchRows == 10_000)
    }

    @Test("A batcher reports the budget it stops at")
    func batcherReportsItsBudget() {
        #expect(OracleRowBatcher(rowsPerBatch: 10, rowBudget: 1_001).expectedRows == 1_001)
        #expect(OracleRowBatcher(rowsPerBatch: 10).expectedRows == nil)
    }
}
