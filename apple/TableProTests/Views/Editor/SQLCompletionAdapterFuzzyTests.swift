import TableProAutocomplete
import TableProPluginKit
@testable import TablePro
import Testing

struct SQLCompletionAdapterFuzzyTests {
    private func fuzzyMatch(pattern: String, target: String) -> Bool {
        let provider = makeDummyProvider()
        if pattern.isEmpty { return true }
        return provider.fuzzyMatchScore(pattern: pattern, target: target) != nil
    }

    private func makeDummyProvider() -> SQLCompletionProvider {
        let schema = SQLSchemaProvider()
        return SQLCompletionProvider(schemaProvider: schema)
    }

    @Test("Exact match returns true")
    func exactMatch() {
        #expect(fuzzyMatch(pattern: "select", target: "select") == true)
    }

    @Test("Prefix match returns true")
    func prefixMatch() {
        #expect(fuzzyMatch(pattern: "sel", target: "select") == true)
    }

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

    @Test("A pattern that is not an in-order subsequence of the target does not match", arguments: [
        "xyz", "tces", "selectfromwhere", "SELECT", "z",
    ])
    func patternOutsideTheTargetDoesNotMatch(pattern: String) {
        #expect(fuzzyMatch(pattern: pattern, target: "select") == false)
    }

    @Test("Empty pattern matches anything")
    func emptyPatternMatchesAnything() {
        #expect(fuzzyMatch(pattern: "", target: "anything") == true)
    }

    @Test("Empty pattern matches empty target")
    func emptyPatternMatchesEmpty() {
        #expect(fuzzyMatch(pattern: "", target: "") == true)
    }

    @Test("ASCII pattern against accented target")
    func asciiPatternAccentedTarget() {
        #expect(fuzzyMatch(pattern: "tbl", target: "table") == true)
    }

    @Test("Unicode characters in both pattern and target")
    func unicodeInBoth() {
        #expect(fuzzyMatch(pattern: "cafe", target: "cafe") == true)
    }

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

    @Test("Single character present returns true")
    func singleCharPresent() {
        #expect(fuzzyMatch(pattern: "s", target: "select") == true)
    }
}
