import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite
struct QueryExecutionOutcomeTests {
    @Test
    func aFinishedQueryIsTheOnlyPlainSuccess() {
        #expect(QueryExecutionOutcome(phase: .finished) == .completed)
    }

    @Test
    func aStoppedQueryIsNotASuccess() {
        #expect(QueryExecutionOutcome(phase: .truncated(reason: .cancelled)) == .stopped)
    }

    @Test
    func aMemoryTruncatedQueryIsNotASuccess() {
        #expect(QueryExecutionOutcome(phase: .truncated(reason: .memoryPressure)) == .interrupted)
    }

    @Test
    func hittingTheRowCapStillCountsAsCompleted() {
        #expect(QueryExecutionOutcome(phase: .truncated(reason: .rowCap(10_000))) == .completed)
        #expect(QueryExecutionOutcome(phase: .truncated(reason: .driverLimit("server limit"))) == .completed)
    }

    @Test
    func clearingMidRunLeavesTheRunInterrupted() {
        #expect(QueryExecutionOutcome(phase: .idle) == .interrupted)
    }

    @Test
    func onlyACompletedRunCarriesNoHistoryMessage() {
        #expect(QueryExecutionOutcome.completed.historyMessage == nil)
        #expect(QueryExecutionOutcome.failed.historyMessage == nil)
        #expect(QueryExecutionOutcome.stopped.historyMessage != nil)
        #expect(QueryExecutionOutcome.interrupted.historyMessage != nil)
    }

    @Test
    func everyOutcomeMapsOntoADistinctActivityOutcome() {
        let mapped: [QueryActivityAttributes.Outcome] = [
            QueryExecutionOutcome.completed.activityOutcome,
            QueryExecutionOutcome.failed.activityOutcome,
            QueryExecutionOutcome.stopped.activityOutcome,
            QueryExecutionOutcome.interrupted.activityOutcome,
        ]

        #expect(Set(mapped).count == mapped.count)
        #expect(!mapped.contains(.running))
    }
}
