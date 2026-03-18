//
//  FuzzyMatcherTests.swift
//  TableProTests
//
//  Tests for FuzzyMatcher fuzzy string matching
//

@testable import TablePro
import Testing

struct FuzzyMatcherTests {
    // MARK: - Basic Matching

    @Test("Empty query matches everything with score 1")
    func emptyQueryMatchesAll() {
        #expect(FuzzyMatcher.score(query: "", candidate: "users") == 1)
        #expect(FuzzyMatcher.score(query: "", candidate: "") == 1)
    }

    @Test("Empty candidate returns 0")
    func emptyCandidateReturnsZero() {
        #expect(FuzzyMatcher.score(query: "abc", candidate: "") == 0)
    }

    @Test("Non-matching query returns 0")
    func nonMatchingQueryReturnsZero() {
        #expect(FuzzyMatcher.score(query: "xyz", candidate: "users") == 0)
    }

    @Test("Partial match where not all characters found returns 0")
    func partialMatchReturnsZero() {
        #expect(FuzzyMatcher.score(query: "uzx", candidate: "users") == 0)
    }

    // MARK: - Scoring Quality

    @Test("Exact match scores higher than substring match")
    func exactMatchScoresHigher() {
        let exact = FuzzyMatcher.score(query: "users", candidate: "users")
        let partial = FuzzyMatcher.score(query: "users", candidate: "all_users_table")
        #expect(exact > partial)
    }

    @Test("Consecutive matches score higher than scattered")
    func consecutiveMatchesScoreHigher() {
        let consecutive = FuzzyMatcher.score(query: "use", candidate: "users")
        let scattered = FuzzyMatcher.score(query: "use", candidate: "u_s_e")
        #expect(consecutive > scattered)
    }

    @Test("Word boundary match scores higher")
    func wordBoundaryMatchScoresHigher() {
        let boundary = FuzzyMatcher.score(query: "ut", candidate: "user_table")
        let middle = FuzzyMatcher.score(query: "ut", candidate: "butter")
        #expect(boundary > middle)
    }

    @Test("Earlier match position scores higher")
    func earlierMatchScoresHigher() {
        let early = FuzzyMatcher.score(query: "a", candidate: "abc")
        let late = FuzzyMatcher.score(query: "a", candidate: "xxa")
        #expect(early > late)
    }

    // MARK: - Case Insensitivity

    @Test("Matching is case insensitive")
    func caseInsensitiveMatching() {
        let lower = FuzzyMatcher.score(query: "users", candidate: "USERS")
        #expect(lower > 0)

        let upper = FuzzyMatcher.score(query: "USERS", candidate: "users")
        #expect(upper > 0)
    }

    // MARK: - Special Characters

    @Test("Handles underscores as word boundaries")
    func handlesUnderscores() {
        let score = FuzzyMatcher.score(query: "ut", candidate: "user_table")
        #expect(score > 0)
    }

    @Test("Handles camelCase as word boundaries")
    func handlesCamelCase() {
        let score = FuzzyMatcher.score(query: "uT", candidate: "userTable")
        #expect(score > 0)
    }

    @Test("Single character query matches")
    func singleCharacterQuery() {
        #expect(FuzzyMatcher.score(query: "u", candidate: "users") > 0)
        #expect(FuzzyMatcher.score(query: "z", candidate: "users") == 0)
    }

    // MARK: - Emoji / Surrogate Handling

    @Test("Emoji in query blocks matching when it cannot match any candidate character")
    func emojiInQueryBlocksWhenUnmatched() {
        let result = FuzzyMatcher.score(query: "🎉u", candidate: "users")
        #expect(result == 0, "Leading emoji that cannot match any candidate character blocks subsequent matches")
    }

    @Test("Emoji in candidate string handled correctly")
    func emojiInCandidateHandled() {
        let result = FuzzyMatcher.score(query: "ab", candidate: "a🎉b")
        #expect(result > 0, "Candidate with emoji between matches should still match")
    }

    @Test("Pure emoji query against plain candidate returns 0")
    func pureEmojiQueryReturnsZero() {
        let result = FuzzyMatcher.score(query: "🎉🔥", candidate: "users")
        #expect(result == 0)
    }

    // MARK: - Performance

    @Test("Very long strings complete in reasonable time")
    func veryLongStringsPerformance() {
        let longCandidate = String(repeating: "abcdefghij", count: 1_000)
        let query = "aej"
        let result = FuzzyMatcher.score(query: query, candidate: longCandidate)
        #expect(result > 0)
    }
}
