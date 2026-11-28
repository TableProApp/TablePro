//
//  LogRedactionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
import Testing

struct LogRedactionTests {
    private static let serverText =
        "ERROR: duplicate key value violates unique constraint \"users_email_key\" Key (email)=(a@b.com) already exists."

    private enum DriverError: LocalizedError {
        case executionFailed(String)

        var errorDescription: String? {
            switch self {
            case .executionFailed(let message): return message
            }
        }
    }

    @Test("The app's public shape of an error never carries the text its description does")
    func publicLogShapeDropsTheDescription() {
        let error = DriverError.executionFailed(Self.serverText)

        #expect(error.localizedDescription.contains("a@b.com"))
        #expect(error.publicLogShape == "DriverError.executionFailed")
    }

    @Test("A core error logs its code in public and keeps its message and the server's words out")
    func coreErrorLogsItsCode() {
        let error = CoreError.Failed(info: ErrorInfo(
            code: "sync.scope.no_key",
            codes: ["sync.transport", "sync.scope.no_key"],
            message: Self.serverText,
            server: nil,
            path: "/Users/someone/Library/history.db",
            secret: nil,
            hostKey: nil,
            tlsFailure: nil,
            ai: nil,
            sync: nil,
            stepUp: nil
        ))

        #expect(error.publicLogShape == "CoreError.Failed(sync.scope.no_key)")
        #expect(CoreError.Cancelled.publicLogShape == "CoreError.Cancelled")
    }
}
