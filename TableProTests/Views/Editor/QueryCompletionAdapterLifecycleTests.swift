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

    // MARK: - Incremental ranking (#2444)

    /// The popup preselects its first row on every incremental update, so a list still ordered for
    /// the prefix it opened with is what Return commits. Every pair here opened with the function
    /// correctly ahead of the keyword, and has to swap once the typed token completes the keyword.
    @MainActor
    @Test(
        "typing to an exact keyword puts it first",
        arguments: [
            (opening: "t", typed: "true", exact: "TRUE", longer: "TRUNCATE"),
            (opening: "n", typed: "null", exact: "NULL", longer: "NULLIF"),
            (opening: "i", typed: "in", exact: "IN", longer: "INSTR"),
            (opening: "i", typed: "is", exact: "IS", longer: "ISNULL"),
            (opening: "r", typed: "regexp", exact: "REGEXP", longer: "REGEXP_REPLACE")
        ]
    )
    func incrementalUpdatePutsTheExactKeywordFirst(
        opening: String,
        typed: String,
        exact: String,
        longer: String
    ) async {
        let labels = await incrementalLabels(opening: opening, typed: typed)

        #expect(labels.first == exact)
        if let exactIndex = labels.firstIndex(of: exact), let longerIndex = labels.firstIndex(of: longer) {
            #expect(exactIndex < longerIndex)
        }
    }

    /// The reporter's own A/B: dismissing the popup and reopening it on the complete token gave the
    /// right order, so an incremental update has to arrive at the same answer.
    @MainActor
    @Test("typing into an open popup lands where reopening it would")
    func incrementalUpdateMatchesAFreshRequest() async {
        let opened = "SELECT * FROM gt_user WHERE t"
        let completed = "SELECT * FROM gt_user WHERE true"

        let controller = EditorControllerFixture.make(string: opened)
        let adapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: .mysql)
        _ = await adapter.completionSuggestionsRequested(
            textView: controller,
            cursorPosition: cursor(atEndOf: opened),
            isManualTrigger: false
        )

        controller.textView.setText(completed)
        for length in (opened.utf16.count + 1)...completed.utf16.count {
            _ = adapter.completionOnCursorMove(
                textView: controller,
                cursorPosition: CursorPosition(range: NSRange(location: length, length: 0))
            )
        }
        let incremental = adapter.completionOnCursorMove(
            textView: controller,
            cursorPosition: cursor(atEndOf: completed)
        )?.map(\.label)

        let freshController = EditorControllerFixture.make(string: completed)
        let freshAdapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: .mysql)
        let fresh = await freshAdapter.completionSuggestionsRequested(
            textView: freshController,
            cursorPosition: cursor(atEndOf: completed),
            isManualTrigger: false
        )?.items.map(\.label)

        #expect(incremental?.first == "TRUE")
        #expect(incremental?.first == fresh?.first)
    }

    /// Deleting a character has to widen the list again, which it only does when each update is
    /// resolved from the session's own candidates rather than from the previous keystroke's.
    @MainActor
    @Test("deleting a character widens the list again")
    func deletingACharacterWidensTheList() async {
        let opened = "SELECT * FROM gt_user WHERE t"
        let controller = EditorControllerFixture.make(string: opened)
        let adapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: .mysql)
        _ = await adapter.completionSuggestionsRequested(
            textView: controller,
            cursorPosition: cursor(atEndOf: opened),
            isManualTrigger: false
        )

        let narrow = "SELECT * FROM gt_user WHERE trun"
        controller.textView.setText(narrow)
        let narrowed = adapter.completionOnCursorMove(
            textView: controller,
            cursorPosition: cursor(atEndOf: narrow)
        )?.map(\.label) ?? []

        let wide = "SELECT * FROM gt_user WHERE tr"
        controller.textView.setText(wide)
        let widened = adapter.completionOnCursorMove(
            textView: controller,
            cursorPosition: cursor(atEndOf: wide)
        )?.map(\.label) ?? []

        #expect(!narrowed.isEmpty)
        #expect(widened.count > narrowed.count)
        #expect(widened.contains("TRUE"))
    }

    // MARK: - The seeded session

    /// The popup seeds itself with statement keywords and shows them while the analyzed request is
    /// in flight, and keeps them when that request comes back suppressed. Ranking used to be
    /// skipped for a session with no analyzed context, so the seeded list came back in declaration
    /// order: DESCRIBE sits ahead of DESC in the keyword table.
    @MainActor
    @Test("a seeded session ranks its exact match first")
    func seededSessionRanksItsExactMatchFirst() async {
        let suppressed = "SELECT * FROM users WHERE "
        let controller = EditorControllerFixture.make(string: suppressed)
        let adapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: .mysql)

        let request = await adapter.completionSuggestionsRequested(
            textView: controller,
            cursorPosition: cursor(atEndOf: suppressed),
            isManualTrigger: false
        )
        #expect(request == nil, "An empty prefix in a WHERE clause is suppressed, leaving the seeded session")

        let typed = suppressed + "desc"
        controller.textView.setText(typed)
        let labels = adapter.completionOnCursorMove(
            textView: controller,
            cursorPosition: cursor(atEndOf: typed)
        )?.map(\.label) ?? []

        #expect(labels.first == "DESC")
        #expect(labels.contains("DESCRIBE"))
    }

    /// Saved favorites have no natural bound, so the seeded window caps what it keeps. Ranking is
    /// linear in the candidate count and runs on every keystroke, and the seeded session is
    /// replaced by an analyzed one as soon as the request lands.
    @MainActor
    @Test("a seeded session bounds what it keeps")
    func seededSessionBoundsWhatItKeeps() async {
        let suppressed = "SELECT * FROM users WHERE "
        let controller = EditorControllerFixture.make(string: suppressed)
        let adapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: .mysql)
        adapter.updateFavoriteKeywords(Dictionary(uniqueKeysWithValues: (0..<5_000).map { index in
            let keyword = String(format: "s%04d", index)
            return (keyword, (name: keyword, query: "SELECT 1"))
        }))

        _ = await adapter.completionSuggestionsRequested(
            textView: controller,
            cursorPosition: cursor(atEndOf: suppressed),
            isManualTrigger: false
        )

        let typed = suppressed + "s"
        controller.textView.setText(typed)
        let labels = adapter.completionOnCursorMove(
            textView: controller,
            cursorPosition: cursor(atEndOf: typed)
        )?.map(\.label) ?? []

        #expect(!labels.isEmpty)
        #expect(labels.count <= 200)
    }

    // MARK: - The session pool

    /// An open popup re-ranks against what the session kept rather than asking again, so the
    /// session keeps more candidates than the popup shows. It still keeps a bounded number: ranking
    /// walks every one of them on every keystroke.
    @MainActor
    @Test("an open session re-ranks a bounded pool wider than the visible list")
    func openSessionReranksABoundedPool() async {
        let items = (0..<5_000).map { SQLCompletionItem.keyword(String(format: "ab%04d", $0)) }
        let service = RankingInputRecordingCompletionService(items: items, poolLimit: 400)
        let adapter = QueryCompletionAdapter(serviceForTesting: service)
        let controller = EditorControllerFixture.make(string: "a")

        _ = await adapter.completionSuggestionsRequested(
            textView: controller,
            cursorPosition: CursorPosition(range: NSRange(location: 1, length: 0)),
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

        #expect(service.rankingInputCounts == [400, 400])
    }

    // MARK: - Helpers

    @MainActor
    private func cursor(atEndOf text: String) -> CursorPosition {
        CursorPosition(range: NSRange(location: text.utf16.count, length: 0))
    }

    @MainActor
    private func incrementalLabels(opening: String, typed: String) async -> [String] {
        let queryPrefix = "SELECT * FROM gt_user WHERE "
        let openingQuery = queryPrefix + opening
        let controller = EditorControllerFixture.make(string: openingQuery)
        let adapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: .mysql)

        _ = await adapter.completionSuggestionsRequested(
            textView: controller,
            cursorPosition: cursor(atEndOf: openingQuery),
            isManualTrigger: false
        )

        let typedQuery = queryPrefix + typed
        controller.textView.setText(typedQuery)

        return adapter.completionOnCursorMove(
            textView: controller,
            cursorPosition: cursor(atEndOf: typedQuery)
        )?.map(\.label) ?? []
    }
}

/// Records what each incremental update was asked to rank, so a test can pin the pool's bound
/// without reaching into the adapter's private session.
@MainActor
private final class RankingInputRecordingCompletionService: QueryCompletionService {
    private let items: [SQLCompletionItem]
    private let poolLimit: Int
    private(set) var rankingInputCounts: [Int] = []

    init(items: [SQLCompletionItem], poolLimit: Int) {
        self.items = items
        self.poolLimit = poolLimit
    }

    var triggerCharacters: Set<String> { [] }

    func seedItems() -> [SQLCompletionItem] { [] }

    func prepare() async {}

    func completions(
        in text: NSString,
        at offset: Int,
        isManualTrigger: Bool
    ) async -> QueryCompletionSession? {
        _ = (text, offset, isManualTrigger)
        return QueryCompletionSession(
            items: Array(items.prefix(40)),
            candidates: Array(items.prefix(poolLimit)),
            replacementRange: NSRange(location: 0, length: 1)
        )
    }

    func rank(_ items: [SQLCompletionItem], prefix: String) -> [SQLCompletionItem] {
        rankingInputCounts.append(items.count)
        let lowerPrefix = prefix.lowercased()
        return items.filter { $0.filterText.hasPrefix(lowerPrefix) }
    }

    func tokenStart(in text: NSString, endingAt offset: Int) -> Int {
        _ = (text, offset)
        return 0
    }

    func updateFavoriteKeywords(_ keywords: [String: (name: String, query: String)]) {
        _ = keywords
    }
}
