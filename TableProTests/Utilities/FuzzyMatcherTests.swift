//
//  FuzzyMatcherTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct FuzzyMatcherTests {
    private func score(_ query: String, _ candidate: String) -> Int {
        FuzzyMatcher.match(query: query, candidate: candidate)?.score ?? 0
    }

    // MARK: - Basic Matching

    @Test("Empty query returns nil")
    func emptyQueryReturnsNil() {
        #expect(FuzzyMatcher.match(query: "", candidate: "users") == nil)
        #expect(FuzzyMatcher.match(query: "", candidate: "") == nil)
    }

    @Test("Empty candidate returns nil")
    func emptyCandidateReturnsNil() {
        #expect(FuzzyMatcher.match(query: "abc", candidate: "") == nil)
    }

    @Test("Non-matching query returns nil")
    func nonMatchingQueryReturnsNil() {
        #expect(FuzzyMatcher.match(query: "xyz", candidate: "users") == nil)
    }

    @Test("Partial match where not all characters found returns nil")
    func partialMatchReturnsNil() {
        #expect(FuzzyMatcher.match(query: "uzx", candidate: "users") == nil)
    }

    @Test("Query longer than candidate returns nil")
    func queryLongerThanCandidateReturnsNil() {
        #expect(FuzzyMatcher.match(query: "userstable", candidate: "users") == nil)
    }

    // MARK: - Scoring Quality

    @Test("Exact match scores higher than substring match")
    func exactMatchScoresHigher() {
        #expect(score("users", "users") > score("users", "all_users_table"))
    }

    @Test("Consecutive matches score higher than scattered")
    func consecutiveMatchesScoreHigher() {
        #expect(score("use", "users") > score("use", "u_s_e"))
    }

    @Test("Word boundary match scores higher")
    func wordBoundaryMatchScoresHigher() {
        #expect(score("ut", "user_table") > score("ut", "butter"))
    }

    @Test("Earlier match position scores higher")
    func earlierMatchScoresHigher() {
        #expect(score("a", "abc") > score("a", "xxa"))
    }

    @Test("Prefix match beats infix match of the same length")
    func prefixBeatsInfix() {
        #expect(score("user", "user_roles") > score("user", "power_user"))
    }

    // MARK: - Case Sensitivity

    @Test("Matching is case insensitive")
    func caseInsensitiveMatching() {
        #expect(score("users", "USERS") > 0)
        #expect(score("USERS", "users") > 0)
    }

    @Test("Exact case match scores higher than cross-case match")
    func exactCaseScoresHigher() {
        #expect(score("Users", "Users") > score("users", "Users"))
    }

    // MARK: - Boundaries

    @Test("Underscore abbreviation matches with boundary-aligned indices")
    func underscoreAbbreviationIndices() {
        let match = FuzzyMatcher.match(query: "uid", candidate: "user_id")
        #expect(match?.matchedIndices == [0, 5, 6])
    }

    @Test("Camel case abbreviation picks boundary alignment over greedy")
    func camelCaseOptimalAlignment() {
        let match = FuzzyMatcher.match(query: "lll", candidate: "SVisualLoggerLogsList")
        #expect(match?.matchedIndices == [7, 13, 17])
    }

    @Test("Consecutive substring reports contiguous indices")
    func consecutiveSubstringIndices() {
        let match = FuzzyMatcher.match(query: "use", candidate: "users")
        #expect(match?.matchedIndices == [0, 1, 2])
    }

    @Test("Dollar sign acts as a word boundary")
    func dollarSignBoundary() {
        #expect(score("bp", "v$buffer_pool") > score("bp", "albpx"))
    }

    @Test("Single character query matches")
    func singleCharacterQuery() {
        #expect(score("u", "users") > 0)
        #expect(FuzzyMatcher.match(query: "z", candidate: "users") == nil)
    }

    // MARK: - Determinism

    @Test("Same input always produces the same result")
    func deterministicResult() {
        let first = FuzzyMatcher.match(query: "ust", candidate: "user_settings_table")
        let second = FuzzyMatcher.match(query: "ust", candidate: "user_settings_table")
        #expect(first == second)
    }

    // MARK: - Emoji / Surrogate Handling

    @Test("Emoji in query blocks matching when it cannot match any candidate character")
    func emojiInQueryBlocksWhenUnmatched() {
        #expect(FuzzyMatcher.match(query: "🎉u", candidate: "users") == nil)
    }

    @Test("Emoji in candidate string handled correctly")
    func emojiInCandidateHandled() {
        let match = FuzzyMatcher.match(query: "ab", candidate: "a🎉b")
        #expect(match?.matchedIndices == [0, 2])
    }

    @Test("Pure emoji query against plain candidate returns nil")
    func pureEmojiQueryReturnsNil() {
        #expect(FuzzyMatcher.match(query: "🎉🔥", candidate: "users") == nil)
    }

    // MARK: - Long Input Fallback

    @Test("Very long candidates fall back to greedy matching with indices")
    func veryLongCandidateGreedyFallback() {
        let longCandidate = String(repeating: "abcdefghij", count: 1_000)
        let match = FuzzyMatcher.match(query: "aej", candidate: longCandidate)
        #expect(match != nil)
        #expect(match?.matchedIndices == [0, 4, 9])
    }

    @Test("Very long queries fall back to greedy matching")
    func veryLongQueryGreedyFallback() {
        let query = String(repeating: "ab", count: 40)
        let candidate = String(repeating: "ab", count: 50)
        let match = FuzzyMatcher.match(query: query, candidate: candidate)
        #expect(match != nil)
        #expect(match?.matchedIndices.count == 80)
    }
}
