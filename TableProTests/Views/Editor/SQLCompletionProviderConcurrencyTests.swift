//
//  SQLCompletionProviderConcurrencyTests.swift
//  TableProTests
//
//  Guards the invariant that filterByPrefix and filterAndRank are pure and
//  safe to call off the main actor. SQLCompletionAdapter runs filterAndRank
//  on a detached task while typing, so concurrent invocations from the main
//  actor's synchronous fast path must not diverge.
//

import TableProPluginKit
@testable import TablePro
import Testing

@Suite("SQL Completion Provider Concurrency")
struct SQLCompletionProviderConcurrencyTests {
    private func makeProvider() -> SQLCompletionProvider {
        SQLCompletionProvider(schemaProvider: SQLSchemaProvider())
    }

    private func makeItems() -> [SQLCompletionItem] {
        ["select", "set", "session", "schema", "savepoint", "score", "scalar"]
            .map { SQLCompletionItem.keyword($0) }
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

    @Test("filterAndRank returns identical results across repeated invocations")
    func filterAndRankIsDeterministic() {
        let provider = makeProvider()
        let items = makeItems()
        let context = makeContext(prefix: "s")

        let first = provider.filterAndRank(items, prefix: "s", context: context)
        let second = provider.filterAndRank(items, prefix: "s", context: context)

        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test("filterByPrefix result is a superset of filterAndRank matches")
    func filterByPrefixSupersetOfRanked() {
        let provider = makeProvider()
        let items = makeItems()

        let filtered = provider.filterByPrefix(items, prefix: "se")
        let ranked = provider.filterAndRank(items, prefix: "se", context: makeContext(prefix: "se"))

        let filteredLabels = Set(filtered.map { $0.label })
        let rankedLabels = Set(ranked.map { $0.label })

        #expect(rankedLabels.isSubset(of: filteredLabels))
    }

    @Test("filterAndRank is safe under concurrent invocations from a detached task")
    func filterAndRankConcurrent() async {
        let provider = makeProvider()
        let items = makeItems()
        let context = makeContext(prefix: "sc")

        let baseline = provider.filterAndRank(items, prefix: "sc", context: context)

        await withTaskGroup(of: [SQLCompletionItem].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    provider.filterAndRank(items, prefix: "sc", context: context)
                }
            }
            for await result in group {
                #expect(result == baseline)
            }
        }
    }

    @Test("filterByPrefix narrows correctly when prefix extends")
    func filterByPrefixNarrowsOnExtension() {
        let provider = makeProvider()
        let items = makeItems()

        let short = provider.filterByPrefix(items, prefix: "s")
        let extended = provider.filterByPrefix(short, prefix: "se")

        let direct = provider.filterByPrefix(items, prefix: "se")
        let directLabels = Set(direct.map { $0.label })
        let extendedLabels = Set(extended.map { $0.label })

        #expect(extendedLabels == directLabels)
        #expect(extended.count <= short.count)
    }
}
