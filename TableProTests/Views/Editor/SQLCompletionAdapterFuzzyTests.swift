//
//  SQLCompletionAdapterFuzzyTests.swift
//  TableProTests
//
//  Regression tests for SQLCompletionAdapter.fuzzyMatch() method.
//

@testable import TablePro
import Testing

@Suite("SQLCompletionAdapter Fuzzy Matching")
struct SQLCompletionAdapterFuzzyTests {
    // MARK: - Exact Match

    @Test("Exact match returns true")
    func exactMatch() {
        #expect(SQLCompletionAdapter.fuzzyMatch(pattern: "select", target: "select") == true)
    }

    // MARK: - Prefix Match

    @Test("Prefix match returns true")
    func prefixMatch() {
        #expect(SQLCompletionAdapter.fuzzyMatch(pattern: "sel", target: "select") == true)
    }

    // MARK: - Scattered Match

    @Test("Scattered characters in order returns true")
    func scatteredMatch() {
        #expect(SQLCompletionAdapter.fuzzyMatch(pattern: "slc", target: "select") == true)
    }

    @Test("First and last character match")
    func firstAndLastMatch() {
        #expect(SQLCompletionAdapter.fuzzyMatch(pattern: "st", target: "select") == true)
    }

    @Test("Scattered match across longer string")
    func scatteredLongerString() {
        #expect(SQLCompletionAdapter.fuzzyMatch(pattern: "usr", target: "users_table") == true)
    }

    // MARK: - No Match

    @Test("No matching characters returns false")
    func noMatch() {
        #expect(SQLCompletionAdapter.fuzzyMatch(pattern: "xyz", target: "select") == false)
    }

    @Test("Characters present but in wrong order returns false")
    func wrongOrderReturnsFalse() {
        #expect(SQLCompletionAdapter.fuzzyMatch(pattern: "tces", target: "select") == false)
    }

    // MARK: - Empty Pattern

    @Test("Empty pattern matches anything")
    func emptyPatternMatchesAnything() {
        #expect(SQLCompletionAdapter.fuzzyMatch(pattern: "", target: "anything") == true)
    }

    @Test("Empty pattern matches empty target")
    func emptyPatternMatchesEmpty() {
        #expect(SQLCompletionAdapter.fuzzyMatch(pattern: "", target: "") == true)
    }

    // MARK: - Pattern Longer Than Target

    @Test("Pattern longer than target returns false")
    func patternLongerThanTarget() {
        #expect(SQLCompletionAdapter.fuzzyMatch(pattern: "selectfromwhere", target: "select") == false)
    }

    // MARK: - Case Sensitivity

    @Test("Matching is case-sensitive by default")
    func caseSensitive() {
        #expect(SQLCompletionAdapter.fuzzyMatch(pattern: "SELECT", target: "select") == false)
    }

    @Test("Same case matches")
    func sameCaseMatches() {
        #expect(SQLCompletionAdapter.fuzzyMatch(pattern: "select", target: "select") == true)
    }

    // MARK: - Unicode

    @Test("ASCII pattern against accented target")
    func asciiPatternAccentedTarget() {
        let result = SQLCompletionAdapter.fuzzyMatch(pattern: "tbl", target: "table")
        #expect(result == true)
    }

    @Test("Unicode characters in both pattern and target")
    func unicodeInBoth() {
        let result = SQLCompletionAdapter.fuzzyMatch(pattern: "cafe", target: "cafe")
        #expect(result == true)
    }

    // MARK: - Large Strings

    @Test("Fuzzy match with large target string")
    func largeTargetString() {
        let largeTarget = String(repeating: "a", count: 10_000) + "xyz"
        #expect(SQLCompletionAdapter.fuzzyMatch(pattern: "xyz", target: largeTarget) == true)
    }

    @Test("No match in large target string")
    func noMatchLargeTarget() {
        let largeTarget = String(repeating: "a", count: 10_000)
        #expect(SQLCompletionAdapter.fuzzyMatch(pattern: "xyz", target: largeTarget) == false)
    }

    @Test("Pattern at beginning of large target")
    func patternAtBeginningOfLargeTarget() {
        let largeTarget = "xyz" + String(repeating: "a", count: 10_000)
        #expect(SQLCompletionAdapter.fuzzyMatch(pattern: "xyz", target: largeTarget) == true)
    }

    // MARK: - Single Characters

    @Test("Single character present returns true")
    func singleCharPresent() {
        #expect(SQLCompletionAdapter.fuzzyMatch(pattern: "s", target: "select") == true)
    }

    @Test("Single character absent returns false")
    func singleCharAbsent() {
        #expect(SQLCompletionAdapter.fuzzyMatch(pattern: "z", target: "select") == false)
    }
}
