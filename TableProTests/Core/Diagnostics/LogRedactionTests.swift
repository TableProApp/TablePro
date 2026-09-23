//
//  LogRedactionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Log redaction")
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
}
