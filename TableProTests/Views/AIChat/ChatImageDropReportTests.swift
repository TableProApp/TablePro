//
//  ChatImageDropReportTests.swift
//  TableProTests
//
//  A drop that attaches some files and discards the rest has to say so. Reporting only when
//  everything failed is what let a mixed drop look like a success, so the prompt went out naming
//  images the model never received.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Chat image drop report")
struct ChatImageDropReportTests {
    @Test("A drop with nothing to report says nothing")
    func noFailuresIsSilent() {
        #expect(ChatImageDropReport.message(attached: 3, failures: []) == nil)
        #expect(ChatImageDropReport.message(attached: 0, failures: []) == nil)
    }

    @Test("A single total failure is reported verbatim")
    func singleFailureIsTheErrorItself() {
        #expect(ChatImageDropReport.message(attached: 0, failures: ["Unsupported image"]) == "Unsupported image")
    }

    @Test("A partial failure names how many landed and how many were offered")
    func partialFailureNamesBothCounts() throws {
        let message = try #require(ChatImageDropReport.message(attached: 1, failures: ["Unsupported image"]))
        #expect(message.contains("1"))
        #expect(message.contains("2"))
        #expect(message.contains("Unsupported image"))
    }

    @Test("Several total failures name the count")
    func manyFailuresNameTheCount() throws {
        let message = try #require(
            ChatImageDropReport.message(attached: 0, failures: ["Unsupported image", "Too large"])
        )
        #expect(message.contains("2"))
        #expect(message.contains("Unsupported image"))
    }

    /// The regression this type exists for: one success beside two failures used to report nothing.
    @Test("A mixed drop is never silent")
    func mixedDropAlwaysReports() {
        #expect(ChatImageDropReport.message(attached: 1, failures: ["a", "b"]) != nil)
    }
}
