//
//  StructureFetchFailureTests.swift
//  TableProTests
//
//  A workspace switch cancels the structure view's opening fetch. The cancelled fetch used to land
//  in the error view as "Swift.CancellationError error 1", with no retry, until Refresh.
//

import Foundation
@testable import TablePro
import Testing

private struct MissingTable: LocalizedError {
    var errorDescription: String? { "Table 'shop.orders' doesn't exist" }
}

struct StructureFetchFailureTests {
    @Test("A fetch cancelled by a workspace switch shows nothing")
    func cancellationIsQuiet() {
        let failure = StructureFetchFailure(CancellationError(), taskIsCancelled: true)

        #expect(failure == .cancelled)
        #expect(failure.message == nil)
    }

    @Test("A CancellationError is a cancellation even when the task itself was not cancelled")
    func cancellationErrorAloneIsCancelled() {
        let failure = StructureFetchFailure(CancellationError(), taskIsCancelled: false)

        #expect(failure == .cancelled)
        #expect(failure.message == nil)
    }

    @Test("A driver error that arrives after the task was cancelled waits for the next fetch")
    func errorAfterCancellationIsCancelled() {
        let failure = StructureFetchFailure(MissingTable(), taskIsCancelled: true)

        #expect(failure == .cancelled)
        #expect(failure.message == nil)
    }

    @Test("A real failure keeps its message for the error view")
    func realFailureKeepsItsMessage() {
        let failure = StructureFetchFailure(MissingTable(), taskIsCancelled: false)

        #expect(failure == .failed("Table 'shop.orders' doesn't exist"))
        #expect(failure.message == "Table 'shop.orders' doesn't exist")
    }
}
