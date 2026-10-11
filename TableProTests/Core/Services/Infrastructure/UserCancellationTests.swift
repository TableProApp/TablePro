//
//  UserCancellationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct UserCancellationTests {
    @Test("Every cancel the user asked for reads as one")
    func userCancelsAreCancellations() {
        let cancels: [any Error] = [
            TabRouterError.userCancelled,
            DatabaseAccessError.userCancelled,
            CancellationError(),
            NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError),
        ]
        for error in cancels {
            #expect(error.isUserCancellation, "\(error)")
        }
    }

    @Test("A failure is not a cancellation")
    func failuresAreNotCancellations() {
        let failures: [any Error] = [
            TabRouterError.connectionNotFound(UUID()),
            TabRouterError.connectFailedInWindow(connectionId: UUID(), underlying: URLError(.timedOut)),
            DatabaseAccessError.timeout("query"),
            NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError),
        ]
        for error in failures {
            #expect(!error.isUserCancellation, "\(error)")
        }
    }
}
