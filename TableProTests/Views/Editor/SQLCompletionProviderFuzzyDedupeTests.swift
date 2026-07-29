//
//  SQLCompletionProviderFuzzyDedupeTests.swift
//  TableProTests
//
//  Guards the invariant that filterByPrefix resolves fuzzy matching once per
//  candidate and that the resulting order matches a from-scratch reference
//  ranking. Catches regressions where the dedupe folds the fuzzy penalty into
//  sortPriority incorrectly or where a step skips its fuzzy pass.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SQL Completion Fuzzy Dedupe")
struct SQLCompletionProviderFuzzyDedupeTests {
    private func makeProvider() -> SQLCompletionProvider {
        SQLCompletionProvider(schemaProvider: SQLSchemaProvider())
    }

    private func makeContext(prefix: String) -> SQLContext {
        SQLContext(
            clauseType: .unknown,
            prefix: prefix,
            prefixRange: 0..<prefix.count,
            dotPrefix: nil,
            tableReferences: [],
            isInsideString: false,
            isInsideComment: false
        )
    }

    /// Build the expected ordering by recomputing the original rank scoring
    /// inline: sortPriority + prefix/equal bonuses + length + per-item fuzzy
    /// penalty for fuzzy-only matches. The production path folds the penalty
    /// into sortPriority during filterByPrefix instead, but the totals must
    /// match exactly.
    private func referenceRank(_ items: [SQLCompletionItem], prefix: String) -> [SQLCompletionItem] {
        let lowerPrefix = prefix.lowercased()
        return items.sorted { a, b in
            referenceScore(for: a, prefix: lowerPrefix) < referenceScore(for: b, prefix: lowerPrefix)
        }
    }

    private func referenceScore(for item: SQLCompletionItem, prefix: String) -> Int {
        var score = item.sortPriority
        if item.filterText.hasPrefix(prefix) { score -= 500 }
        if item.filterText == prefix { score -= 1_000 }
        score += (item.label as NSString).length
        if !prefix.isEmpty {
            if !item.filterText.hasPrefix(prefix) && !item.filterText.contains(prefix) {
                if let fuzzy = referenceFuzzyScore(pattern: prefix, target: item.filterText) {
                    score += fuzzy
                }
            }
        }
        return score
    }

    private func referenceFuzzyScore(pattern: String, target: String) -> Int? {
        let nsPattern = pattern as NSString
        let nsTarget = target as NSString
        let patternLen = nsPattern.length
        let targetLen = nsTarget.length
        guard patternLen > 0, targetLen > 0 else { return nil }

        var patternIdx = 0
        var targetIdx = 0
        var gaps = 0
        var consecutiveMatches = 0
        var maxConsecutive = 0
        var lastMatchIdx = -1

        while patternIdx < patternLen && targetIdx < targetLen {
            let pChar = nsPattern.character(at: patternIdx)
            let tChar = nsTarget.character(at: targetIdx)
            if pChar == tChar {
                if lastMatchIdx == targetIdx - 1 {
                    consecutiveMatches += 1
                    maxConsecutive = max(maxConsecutive, consecutiveMatches)
                } else {
                    if lastMatchIdx >= 0 {
                        gaps += targetIdx - lastMatchIdx - 1
                    }
                    consecutiveMatches = 1
                }
                lastMatchIdx = targetIdx
                patternIdx += 1
            }
            targetIdx += 1
        }
        guard patternIdx == patternLen else { return nil }

        let basePenalty = 50
        let gapPenalty = gaps * 10
        let consecutiveBonus = maxConsecutive * 15
        return max(0, basePenalty + gapPenalty - consecutiveBonus)
    }

    @Test("filterAndRank order matches a from-scratch reference rank")
    func orderMatchesReferenceRank() {
        let provider = makeProvider()
        let items: [SQLCompletionItem] = [
            "select", "set", "session", "schema", "savepoint",
            "score", "scalar", "substring", "smallint", "show",
            "sum", "system_user", "some"
        ].map { SQLCompletionItem.keyword($0) }

        let prefixes = ["s", "se", "ses", "sch", "su", "sm", "sx", "slc"]
        for prefix in prefixes {
            let context = makeContext(prefix: prefix)
            let actual = provider.filterAndRank(items, prefix: prefix, context: context)
            let expected = referenceRank(
                items.filter { item in
                    item.filterText.hasPrefix(prefix)
                        || item.filterText.contains(prefix)
                        || referenceFuzzyScore(pattern: prefix, target: item.filterText) != nil
                },
                prefix: prefix
            )
            let actualLabels = actual.map { $0.label }
            let expectedLabels = expected.map { $0.label }
            #expect(actualLabels == expectedLabels, "Prefix '\(prefix)' produced a different order")
        }
    }

    @Test("filterByPrefix populates matchedRanges for all surviving candidates")
    func matchedRangesPopulatedAfterFilter() {
        let provider = makeProvider()
        let items = ["select", "set", "session", "schema", "savepoint", "scalar"]
            .map { SQLCompletionItem.keyword($0) }

        let filtered = provider.filterByPrefix(items, prefix: "slc")
        #expect(!filtered.isEmpty)
        for item in filtered {
            #expect(!item.matchedRanges.isEmpty, "matchedRanges missing for \(item.label)")
        }
    }

    @Test("filterByPrefix resets matchedRanges when prefix is empty")
    func matchedRangesResetOnEmptyPrefix() {
        let provider = makeProvider()
        var items = ["select", "set"].map { SQLCompletionItem.keyword($0) }
        items[0].matchedRanges = [0..<2]

        let filtered = provider.filterByPrefix(items, prefix: "")
        for item in filtered {
            #expect(item.matchedRanges.isEmpty)
        }
    }

    @Test("filterByPrefix records the fuzzy penalty without mutating sortPriority")
    func fuzzyPenaltyRecordedOnce() {
        let provider = makeProvider()
        let items = ["ssl_certificate", "session_variables"]
            .map { SQLCompletionItem.keyword($0) }

        let basePriority = SQLCompletionKind.keyword.basePriority
        let filtered = provider.filterByPrefix(items, prefix: "slc")

        #expect(filtered.count == 1)
        #expect(filtered[0].label == "SSL_CERTIFICATE")
        let expectedPenalty = referenceFuzzyScore(pattern: "slc", target: "ssl_certificate") ?? 0
        #expect(filtered[0].sortPriority == basePriority)
        #expect(filtered[0].fuzzyPenalty == expectedPenalty)
    }

    @Test("re-filtering a prior result is idempotent for fuzzy candidates")
    func reFilteringIsIdempotent() {
        let provider = makeProvider()
        let items = ["ssl_certificate", "scalar_function", "select"]
            .map { SQLCompletionItem.keyword($0) }

        let once = provider.filterByPrefix(items, prefix: "slc")
        let twice = provider.filterByPrefix(once, prefix: "slc")
        let context = makeContext(prefix: "slc")

        let rankedOnce = provider.rankResults(once, prefix: "slc", context: context)
        let rankedTwice = provider.rankResults(twice, prefix: "slc", context: context)

        #expect(once.map { $0.fuzzyPenalty } == twice.map { $0.fuzzyPenalty })
        #expect(once.map { $0.sortPriority } == twice.map { $0.sortPriority })
        #expect(rankedOnce.map { $0.label } == rankedTwice.map { $0.label })
    }
}
