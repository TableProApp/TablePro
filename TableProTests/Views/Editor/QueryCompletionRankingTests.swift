//
//  QueryCompletionRankingTests.swift
//  TableProTests
//
//  The ranking behind #2444, at the provider and service level: a completed token leads, the
//  session keeps enough candidates for a longer prefix to reach one, and equal scores keep the
//  order the generator emitted them in.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Query Completion Ranking")
struct QueryCompletionRankingTests {
    // MARK: - The session pool

    /// The popup shows `maxSuggestions` candidates, and a session that kept only those could not
    /// answer a longer prefix. PostgreSQL declares more `T`-prefixed functions than the popup shows
    /// rows, every one of them outranking the `TRUE` keyword for the single letter `t`, so `TRUE`
    /// was cut before the session was stored and typing `rue` re-ranked a set it was never in.
    @Test("a candidate ranked out of the visible list still leads once the prefix reaches it")
    func candidateBelowTheDisplayCutStillLeads() {
        let provider = SQLCompletionProvider(schemaProvider: nil)
        let context = SQLContext.unanalyzed
        let crowd = (0..<60).map { SQLCompletionItem.function("to_something_\($0)", signature: "()") }
        let candidates = crowd + [SQLCompletionItem.keyword("TRUE")]

        let shown = provider.filterRankAndLimit(candidates, prefix: "t", context: context)
        #expect(!shown.contains { $0.label == "TRUE" }, "The crowd fills the visible list at 't'")

        let pool = provider.filterAndRank(candidates, prefix: "t", context: context)
        let completed = provider.filterRankAndLimit(pool, prefix: "true", context: context)

        #expect(completed.first?.label == "TRUE")
    }

    @Test("a request keeps a wider pool than it shows")
    func requestKeepsAWiderPoolThanItShows() async {
        let provider = SQLCompletionProvider(schemaProvider: nil, databaseType: .postgresql)
        let text = "SELECT * FROM gt_user WHERE t"

        let session = await provider.completionSession(text: text, cursorPosition: text.utf16.count)

        #expect(!session.items.isEmpty)
        #expect(session.candidates.count >= session.items.count)
        #expect(session.candidates.starts(with: session.items))
    }

    // MARK: - Ordering

    @Test("a completed token outranks the longer candidates it prefixes")
    func completedTokenOutranksLongerCandidates() {
        let provider = SQLCompletionProvider(schemaProvider: nil)
        let items = [
            SQLCompletionItem.function("TRUNCATE", signature: "TRUNCATE(n, decimals)"),
            SQLCompletionItem.keyword("TRUE")
        ]

        let opening = provider.filterAndRank(items, prefix: "t", context: .unanalyzed)
        let completed = provider.filterAndRank(items, prefix: "true", context: .unanalyzed)

        #expect(opening.first?.label == "TRUNCATE", "A function outranks a keyword at a bare 't'")
        #expect(completed.first?.label == "TRUE")
    }

    /// Ties keep the order the candidate generator emitted them in, which carries meaning:
    /// statement keywords are declared in the order they are offered. `sorted(by:)` is documented
    /// as not stable, so the position is carried into the comparison rather than assumed.
    @Test("candidates that score alike keep the order they were generated in")
    func tiedScoresKeepGeneratedOrder() {
        let provider = SQLCompletionProvider(schemaProvider: nil)
        let items = [
            SQLCompletionItem.keyword("AXLE"),
            SQLCompletionItem.keyword("ABLE"),
            SQLCompletionItem.keyword("ACME")
        ]

        let ranked = provider.rankResults(items, prefix: "a", context: .unanalyzed)
        let reversed = provider.rankResults(items.reversed(), prefix: "a", context: .unanalyzed)

        #expect(ranked.map(\.label) == ["AXLE", "ABLE", "ACME"])
        #expect(reversed.map(\.label) == ["ACME", "ABLE", "AXLE"])
    }

    // MARK: - MongoDB

    /// MongoDB ranks by anchored match then by kind priority, and a shell method outranks a
    /// keyword. Without a tier for the completed token, a longer method led the keyword the user
    /// had finished typing.
    @MainActor
    @Test("a completed MongoDB token leads the longer candidate it prefixes")
    func mongoCompletedTokenLeads() {
        let service = MongoCompletionService(schemaProvider: nil, databaseType: .mongodb)
        let items = [
            SQLCompletionItem.function("statsDetail", signature: "()"),
            SQLCompletionItem.keyword("stats")
        ]

        let ranked = service.rank(items, prefix: "stats")

        #expect(ranked.first?.filterText == "stats")
        #expect(ranked.count == 2)
    }

    /// A wide document schema can sample thousands of field paths, and an empty opening prefix
    /// filters none of them away, so the pool has to be cut rather than merely preferred.
    @MainActor
    @Test("a MongoDB session bounds what it keeps even with no opening prefix")
    func mongoSessionBoundsAnEmptyPrefixPool() async {
        let service = MongoCompletionService(schemaProvider: nil, databaseType: .mongodb)
        let text = "db.orders.aggregate([{ $" as NSString

        let session = await service.completions(in: text, at: text.length, isManualTrigger: true)

        #expect(session != nil)
        #expect((session?.candidates.count ?? 0) <= 400)
    }

    @MainActor
    @Test("MongoDB collection methods still rank the exact method first")
    func mongoCollectionMethodsRank() {
        let service = MongoCompletionService(schemaProvider: nil, databaseType: .mongodb)
        let items = [
            SQLCompletionItem.function("findOne", signature: "()"),
            SQLCompletionItem.function("findOneAndUpdate", signature: "()"),
            SQLCompletionItem.function("find", signature: "()")
        ]

        let ranked = service.rank(items, prefix: "find")

        #expect(ranked.map(\.label) == ["find", "findOne", "findOneAndUpdate"])
    }
}
