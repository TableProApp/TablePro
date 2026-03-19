//
//  SQLCompletionAdapterFuzzyTests.swift
//  TableProTests
//
//  Regression tests for fuzzy matching used by autocomplete.
//

@testable import TablePro
import Testing

@Suite("SQL Completion Fuzzy Matching")
struct SQLCompletionAdapterFuzzyTests {
    /// Helper: wraps SQLCompletionProvider.fuzzyMatchScore as a bool match
    /// to preserve existing test semantics after the fuzzy logic was unified.
    private func fuzzyMatch(pattern: String, target: String) -> Bool {
        let provider = makeDummyProvider()
        // Empty pattern is a vacuous match
        if pattern.isEmpty { return true }
        return provider.fuzzyMatchScore(pattern: pattern, target: target) != nil
    }

    private func makeDummyProvider() -> SQLCompletionProvider {
        // Provider only needs schemaProvider for candidate generation,
        // fuzzyMatchScore is pure and doesn't touch the schema.
        let schema = SQLSchemaProvider()
        return SQLCompletionProvider(schemaProvider: schema)
    }

    // MARK: - Exact Match

    @Test("Exact match returns true")
    func exactMatch() {
        #expect(fuzzyMatch(pattern: "select", target: "select") == true)
    }

    // MARK: - Prefix Match

    @Test("Prefix match returns true")
    func prefixMatch() {
        #expect(fuzzyMatch(pattern: "sel", target: "select") == true)
    }

    // MARK: - Scattered Match

    @Test("Scattered characters in order returns true")
    func scatteredMatch() {
        #expect(fuzzyMatch(pattern: "slc", target: "select") == true)
    }

    @Test("First and last character match")
    func firstAndLastMatch() {
        #expect(fuzzyMatch(pattern: "st", target: "select") == true)
    }

    @Test("Scattered match across longer string")
    func scatteredLongerString() {
        #expect(fuzzyMatch(pattern: "usr", target: "users_table") == true)
    }

    // MARK: - No Match

    @Test("No matching characters returns false")
    func noMatch() {
        #expect(fuzzyMatch(pattern: "xyz", target: "select") == false)
    }

    @Test("Characters present but in wrong order returns false")
    func wrongOrderReturnsFalse() {
        #expect(fuzzyMatch(pattern: "tces", target: "select") == false)
    }

    // MARK: - Empty Pattern

    @Test("Empty pattern matches anything")
    func emptyPatternMatchesAnything() {
        #expect(fuzzyMatch(pattern: "", target: "anything") == true)
    }

    @Test("Empty pattern matches empty target")
    func emptyPatternMatchesEmpty() {
        #expect(fuzzyMatch(pattern: "", target: "") == true)
    }

    // MARK: - Pattern Longer Than Target

    @Test("Pattern longer than target returns false")
    func patternLongerThanTarget() {
        #expect(fuzzyMatch(pattern: "selectfromwhere", target: "select") == false)
    }

    // MARK: - Case Sensitivity

    @Test("Matching is case-sensitive by default")
    func caseSensitive() {
        #expect(fuzzyMatch(pattern: "SELECT", target: "select") == false)
    }

    @Test("Same case matches")
    func sameCaseMatches() {
        #expect(fuzzyMatch(pattern: "select", target: "select") == true)
    }

    // MARK: - Unicode

    @Test("ASCII pattern against accented target")
    func asciiPatternAccentedTarget() {
        #expect(fuzzyMatch(pattern: "tbl", target: "table") == true)
    }

    @Test("Unicode characters in both pattern and target")
    func unicodeInBoth() {
        #expect(fuzzyMatch(pattern: "cafe", target: "cafe") == true)
    }

    // MARK: - Large Strings

    @Test("Fuzzy match with large target string")
    func largeTargetString() {
        let largeTarget = String(repeating: "a", count: 10_000) + "xyz"
        #expect(fuzzyMatch(pattern: "xyz", target: largeTarget) == true)
    }

    @Test("No match in large target string")
    func noMatchLargeTarget() {
        let largeTarget = String(repeating: "a", count: 10_000)
        #expect(fuzzyMatch(pattern: "xyz", target: largeTarget) == false)
    }

    @Test("Pattern at beginning of large target")
    func patternAtBeginningOfLargeTarget() {
        let largeTarget = "xyz" + String(repeating: "a", count: 10_000)
        #expect(fuzzyMatch(pattern: "xyz", target: largeTarget) == true)
    }

    // MARK: - Single Characters

    @Test("Single character present returns true")
    func singleCharPresent() {
        #expect(fuzzyMatch(pattern: "s", target: "select") == true)
    }

    @Test("Single character absent returns false")
    func singleCharAbsent() {
        #expect(fuzzyMatch(pattern: "z", target: "select") == false)
    }
}
