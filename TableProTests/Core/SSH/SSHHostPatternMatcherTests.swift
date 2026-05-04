//
//  SSHHostPatternMatcherTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SSH host pattern matcher")
struct SSHHostPatternMatcherTests {
    @Test("Exact match")
    func testExactMatch() {
        let patterns = [HostPattern(glob: "bastion", negated: false)]
        #expect(SSHHostPatternMatcher.matches(host: "bastion", patterns: patterns))
        #expect(!SSHHostPatternMatcher.matches(host: "other", patterns: patterns))
    }

    @Test("Star glob")
    func testStarGlob() {
        let patterns = [HostPattern(glob: "*.aws", negated: false)]
        #expect(SSHHostPatternMatcher.matches(host: "db.aws", patterns: patterns))
        #expect(SSHHostPatternMatcher.matches(host: "deep.nested.aws", patterns: patterns))
        #expect(!SSHHostPatternMatcher.matches(host: "db.gcp", patterns: patterns))
    }

    @Test("Question mark glob")
    func testQuestionMarkGlob() {
        let patterns = [HostPattern(glob: "?est", negated: false)]
        #expect(SSHHostPatternMatcher.matches(host: "test", patterns: patterns))
        #expect(SSHHostPatternMatcher.matches(host: "best", patterns: patterns))
        #expect(!SSHHostPatternMatcher.matches(host: "fest1", patterns: patterns))
    }

    @Test("Negation excludes match")
    func testNegation() {
        let patterns = [
            HostPattern(glob: "*.aws", negated: false),
            HostPattern(glob: "*.dev.aws", negated: true),
        ]
        #expect(SSHHostPatternMatcher.matches(host: "prod.aws", patterns: patterns))
        #expect(!SSHHostPatternMatcher.matches(host: "stage.dev.aws", patterns: patterns))
    }

    @Test("Empty pattern list never matches")
    func testEmptyList() {
        #expect(!SSHHostPatternMatcher.matches(host: "anything", patterns: []))
    }

    @Test("Only-negation list never matches")
    func testOnlyNegation() {
        let patterns = [HostPattern(glob: "internal", negated: true)]
        #expect(!SSHHostPatternMatcher.matches(host: "external", patterns: patterns))
        #expect(!SSHHostPatternMatcher.matches(host: "internal", patterns: patterns))
    }

    @Test("Pattern list parsing")
    func testParsePatternList() {
        let parsed = SSHHostPatternMatcher.parsePatternList("*.aws !*.dev.aws prod-*")
        #expect(parsed.count == 3)
        #expect(parsed[0].glob == "*.aws" && !parsed[0].negated)
        #expect(parsed[1].glob == "*.dev.aws" && parsed[1].negated)
        #expect(parsed[2].glob == "prod-*" && !parsed[2].negated)
    }

    @Test("Pattern list parsing with commas")
    func testParsePatternListCommas() {
        let parsed = SSHHostPatternMatcher.parsePatternList("a,b, c")
        #expect(parsed.map(\.glob) == ["a", "b", "c"])
    }
}
