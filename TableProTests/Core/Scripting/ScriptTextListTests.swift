//
//  ScriptTextListTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct ScriptTextListTests {
    private let list = ScriptTextList(["production", "reporting", "eu"])

    @Test("It reads as the array it was built from")
    func readsAsArray() {
        #expect(list.count == 3)
        #expect(list as? [String] == ["production", "reporting", "eu"])
        #expect(ScriptTextList([]).firstObject == nil)
    }

    @Test("One text matches a whole member, ignoring case")
    func containsOneItem() {
        #expect(list.scriptingContains("production"))
        #expect(list.scriptingContains("EU"))
        #expect(!list.scriptingContains("prod"))
        #expect(!list.scriptingContains("staging"))
    }

    @Test("A list matches a run of members in order")
    func containsSublist() {
        #expect(list.scriptingContains(["production", "reporting"]))
        #expect(list.scriptingContains(["Reporting", "eu"]))
        #expect(!list.scriptingContains(["production", "eu"]))
        #expect(!list.scriptingContains(["eu", "production"]))
        #expect(!list.scriptingContains(["production", "reporting", "eu", "x"]))
        #expect(list.scriptingContains([String]()))
    }

    @Test("A value that is not text matches nothing")
    func nonTextMatchesNothing() {
        #expect(!list.scriptingContains(NSNumber(value: 1)))
        #expect(!list.scriptingContains(["production", NSNumber(value: 1)] as [Any]))
        #expect(!ScriptTextList([]).scriptingContains("production"))
    }
}
