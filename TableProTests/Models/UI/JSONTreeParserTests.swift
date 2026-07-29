//
//  JSONTreeParserTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("JSONTreeParser")
struct JSONTreeParserTests {
    @Test("Long string nodes keep the full display value")
    func longStringNodesKeepFullDisplayValue() {
        let longString = String(repeating: "abcdefghij", count: 12)
        let json = "{\"message\":\"\(longString)\"}"

        let result = JSONTreeParser.parse(json)
        guard case .success(let root) = result else {
            Issue.record("Expected JSONTreeParser.parse to succeed")
            return
        }

        guard let messageNode = root.children.first else {
            Issue.record("Expected a child node for message")
            return
        }

        #expect(messageNode.valueType == .string)
        #expect(messageNode.rawValue == longString)
        #expect(messageNode.displayValue == "\"\(longString)\"")
        #expect(!messageNode.displayValue.contains("..."))
    }

    @Test("Tree parser still rejects oversized documents")
    func oversizedDocumentStillRejected() {
        let oversizedValue = String(repeating: "a", count: 100_001)
        let json = "{\"message\":\"\(oversizedValue)\"}"

        let result = JSONTreeParser.parse(json)
        guard case .failure(let error) = result else {
            Issue.record("Expected JSONTreeParser.parse to fail for oversized input")
            return
        }

        switch error {
        case .tooLarge:
            break
        case .invalidJSON:
            Issue.record("Expected oversized input to hit the tooLarge guard first")
        }
    }
}
