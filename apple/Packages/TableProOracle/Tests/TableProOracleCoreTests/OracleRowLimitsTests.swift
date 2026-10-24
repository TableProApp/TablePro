import OracleNIO
@testable import TableProOracleCore
import Testing

struct OracleRowLimitsTests {
    @Test("A read that keeps every row fetches a thousand rows per round trip")
    func collectedReadFetchesInLargeBatches() {
        let options = OracleRowLimits.collecting(StatementOptions(autoCommit: true))

        #expect(options.prefetchRows == 1_000)
        #expect(options.arraySize == 1_000)
        #expect(options.autoCommit)
    }
}
