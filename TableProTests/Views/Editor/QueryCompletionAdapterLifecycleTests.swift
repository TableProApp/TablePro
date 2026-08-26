//
//  QueryCompletionAdapterLifecycleTests.swift
//  TableProTests
//
//  Guards the invariants behind the autocomplete delegate-lifetime fix (#1731):
//  the completion engine produces keyword suggestions before any schema is
//  attached, and reconfiguring the adapter across nil/non-nil schema transitions
//  keeps it functional. The SwiftUI onDisappear/onAppear delegate attachment that
//  caused the original dropout is an AppKit lifecycle behaviour and is not
//  deterministically unit-testable; these tests cover the logic the fix relies on.
//

import CodeEditSourceEditor
import CodeEditTextView
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Query Completion Adapter Lifecycle")
struct QueryCompletionAdapterLifecycleTests {
    @Test("engine returns keyword completions with no schema provider")
    func keywordsAvailableWithoutSchema() async {
        let engine = CompletionEngine(schemaProvider: nil, databaseType: .postgresql)
        let context = await engine.getCompletions(text: "SEL", cursorPosition: 3)
        #expect(context?.items.contains { $0.label == "SELECT" } == true)
    }

    @Test("engine returns keyword completions with no schema and no database type")
    func keywordsAvailableWithoutSchemaOrDatabaseType() async {
        let engine = CompletionEngine(schemaProvider: nil, databaseType: nil)
        let context = await engine.getCompletions(text: "SEL", cursorPosition: 3)
        #expect(context?.items.contains { $0.label == "SELECT" } == true)
    }

    @MainActor
    @Test("configure across nil and non-nil schema keeps the adapter functional")
    func configureAcrossSchemaTransitionsKeepsAdapterUsable() {
        let adapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: nil)
        #expect(!adapter.completionTriggerCharacters().isEmpty)

        adapter.configure(schemaProvider: nil, databaseType: .postgresql)
        adapter.configure(schemaProvider: SQLSchemaProvider(), databaseType: .postgresql)
        adapter.configure(schemaProvider: nil, databaseType: .mysql)

        #expect(!adapter.completionTriggerCharacters().isEmpty)
    }

    /// Rebuilding the service drops the open completion session. A refresh in any window of the
    /// connection bumps the profile revision the editor's task keys on, so an unconditional
    /// rebuild closed the popup under whoever was typing.
    @MainActor
    @Test("configuring with unchanged inputs does not rebuild the service")
    func configureWithUnchangedInputsKeepsTheService() {
        let provider = SQLSchemaProvider()
        let adapter = QueryCompletionAdapter(schemaProvider: provider, databaseType: .postgresql)
        let profile = QueryCompletionProfile(
            resolvedDialect: nil,
            statementCompletions: [],
            revision: "rev-1"
        )
        adapter.configure(schemaProvider: provider, databaseType: .postgresql, profile: profile)
        let first = adapter.serviceIdentityForTesting

        adapter.configure(schemaProvider: provider, databaseType: .postgresql, profile: profile)

        #expect(adapter.serviceIdentityForTesting == first)
    }

    @MainActor
    @Test("a changed profile revision rebuilds the service")
    func changedProfileRevisionRebuildsTheService() {
        let provider = SQLSchemaProvider()
        let adapter = QueryCompletionAdapter(schemaProvider: provider, databaseType: .postgresql)
        adapter.configure(
            schemaProvider: provider,
            databaseType: .postgresql,
            profile: QueryCompletionProfile(resolvedDialect: nil, statementCompletions: [], revision: "rev-1")
        )
        let first = adapter.serviceIdentityForTesting

        adapter.configure(
            schemaProvider: provider,
            databaseType: .postgresql,
            profile: QueryCompletionProfile(resolvedDialect: nil, statementCompletions: [], revision: "rev-2")
        )

        #expect(adapter.serviceIdentityForTesting != first)
    }

    @MainActor
    @Test("a changed schema provider rebuilds the service")
    func changedSchemaProviderRebuildsTheService() {
        let adapter = QueryCompletionAdapter(schemaProvider: SQLSchemaProvider(), databaseType: .postgresql)
        adapter.configure(schemaProvider: SQLSchemaProvider(), databaseType: .postgresql)
        let first = adapter.serviceIdentityForTesting

        adapter.configure(schemaProvider: SQLSchemaProvider(), databaseType: .postgresql)

        #expect(adapter.serviceIdentityForTesting != first)
    }

    @MainActor
    @Test("incremental completion reranks exact keywords")
    func incrementalCompletionReranksExactKeywords() async {
        let cases = [
            (initial: "t", completed: "true", exact: "TRUE", longer: "TRUNCATE"),
            (initial: "n", completed: "null", exact: "NULL", longer: "NULLIF"),
            (initial: "i", completed: "in", exact: "IN", longer: "INSTR")
        ]

        for testCase in cases {
            let labels = await incrementalLabels(initial: testCase.initial, completed: testCase.completed)
            let exactIndex = labels.firstIndex(of: testCase.exact)
            let longerIndex = labels.firstIndex(of: testCase.longer)

            #expect(exactIndex != nil, "Missing exact candidate \(testCase.exact)")
            #expect(longerIndex != nil, "Missing longer candidate \(testCase.longer)")
            if let exactIndex, let longerIndex {
                #expect(
                    exactIndex < longerIndex,
                    "Expected \(testCase.exact) before \(testCase.longer) for \(testCase.completed)"
                )
            }
        }
    }

    @MainActor
    @Test("seed completion filters without ranking all favorites")
    func seedCompletionFiltersWithoutRankingAllFavorites() async {
        let initialQuery = "SELECT * WHERE t"
        let controller = EditorControllerFixture.make(string: initialQuery)
        let adapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: .mysql)
        let initialCursor = CursorPosition(range: NSRange(location: initialQuery.utf16.count, length: 0))

        _ = await adapter.completionSuggestionsRequested(
            textView: controller,
            cursorPosition: initialCursor,
            isManualTrigger: false
        )
        adapter.completionWindowDidClose()

        let favorites = Dictionary(uniqueKeysWithValues: (0..<1_000).map { index in
            let keyword = String(format: "s%04d", index)
            return (keyword, (name: keyword, query: "SELECT 1"))
        })
        adapter.updateFavoriteKeywords(favorites)

        let seedQuery = "s"
        controller.textView.setText(seedQuery)
        let seedCursor = CursorPosition(range: NSRange(location: seedQuery.utf16.count, length: 0))
        adapter.seedSessionForTesting(textView: controller, cursorPosition: seedCursor)

        let labels = adapter.completionOnCursorMove(
            textView: controller,
            cursorPosition: seedCursor
        )?.map(\.label) ?? []

        #expect(labels.first == "SELECT")
        #expect(labels.contains("s0000"))
    }

    @MainActor
    @Test("resolved completion narrows the next ranking input")
    func resolvedCompletionNarrowsTheNextRankingInput() async {
        let items = (0..<500).flatMap { index in
            [
                SQLCompletionItem.keyword(String(format: "ab%03d", index)),
                SQLCompletionItem.keyword(String(format: "ac%03d", index))
            ]
        }
        let service = RankingInputRecordingCompletionService(items: items)
        let adapter = QueryCompletionAdapter(serviceForTesting: service)
        let controller = EditorControllerFixture.make(string: "a")
        let initialCursor = CursorPosition(range: NSRange(location: 1, length: 0))

        _ = await adapter.completionSuggestionsRequested(
            textView: controller,
            cursorPosition: initialCursor,
            isManualTrigger: false
        )

        controller.textView.setText("ab")
        _ = adapter.completionOnCursorMove(
            textView: controller,
            cursorPosition: CursorPosition(range: NSRange(location: 2, length: 0))
        )

        controller.textView.setText("ab0")
        _ = adapter.completionOnCursorMove(
            textView: controller,
            cursorPosition: CursorPosition(range: NSRange(location: 3, length: 0))
        )

        #expect(service.rankingInputCounts == [1_000, 500])
    }

    @MainActor
    private func incrementalLabels(initial: String, completed: String) async -> [String] {
        let queryPrefix = "SELECT * WHERE "
        let initialQuery = queryPrefix + initial
        let controller = EditorControllerFixture.make(string: initialQuery)
        let adapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: .mysql)
        let initialCursor = CursorPosition(range: NSRange(location: initialQuery.utf16.count, length: 0))

        _ = await adapter.completionSuggestionsRequested(
            textView: controller,
            cursorPosition: initialCursor,
            isManualTrigger: false
        )

        let completedQuery = queryPrefix + completed
        controller.textView.setText(completedQuery)
        let completedCursor = CursorPosition(range: NSRange(location: completedQuery.utf16.count, length: 0))

        return adapter.completionOnCursorMove(
            textView: controller,
            cursorPosition: completedCursor
        )?.map(\.label) ?? []
    }
}

@MainActor
private final class RankingInputRecordingCompletionService: QueryCompletionService {
    private let items: [SQLCompletionItem]
    private(set) var rankingInputCounts: [Int] = []

    init(items: [SQLCompletionItem]) {
        self.items = items
    }

    var triggerCharacters: Set<String> { [] }

    func seedItems() -> [SQLCompletionItem] { [] }

    func prepare() async {}

    func completions(
        in text: NSString,
        at offset: Int,
        isManualTrigger: Bool
    ) async -> QueryCompletionSession? {
        _ = text
        _ = offset
        _ = isManualTrigger
        return QueryCompletionSession(items: items, replacementRange: NSRange(location: 0, length: 1))
    }

    func filter(_ items: [SQLCompletionItem], prefix: String) -> [SQLCompletionItem] {
        let lowerPrefix = prefix.lowercased()
        return items.filter { $0.filterText.hasPrefix(lowerPrefix) }
    }

    func rank(_ items: [SQLCompletionItem], prefix: String) -> [SQLCompletionItem] {
        rankingInputCounts.append(items.count)
        return filter(items, prefix: prefix)
    }

    func tokenStart(in text: NSString, endingAt offset: Int) -> Int {
        _ = text
        return 0
    }

    func updateFavoriteKeywords(_ keywords: [String: (name: String, query: String)]) {
        _ = keywords
    }
}
